# Couchbase 7.0.3 → 8.0.3 and Sync Gateway 2.1 → 4.1 migration kit

Scripts and notes for a **parallel-cluster migration**. We build a new Couchbase Server 8.0.3 cluster beside the old 7.0.3 one and copy data across with XDCR. Then we bring the index definitions over, stand up Sync Gateway 4.1 against the new cluster, and cut clients over. The old environment is never modified.

Every install script targets **Oracle Linux 8** on EC2 unless noted. Every one is **safe to re-run**: each step checks whether its work is already done, so if a run fails partway, fix the cause and run the same script again.

## What's in this folder

| File | Runs on | Purpose |
|---|---|---|
| [`getting-started-guide.md`](getting-started-guide.md) | Your laptop | **Start here.** Step-by-step walkthrough of these scripts in run order: multi-node Couchbase 8.0.3 cluster (with `cb-certs.sh`), multi-node Sync Gateway 4.1, then `migrate-indexes.sh`. |
| [`user-data-ol8.sh`](user-data-ol8.sh) | One OL8 lab server | **Old environment (lab).** Couchbase Server 7.0.3 and Sync Gateway 2.1 on one box, with sample data and users. |
| [`EC2_Lab_Setup.md`](EC2_Lab_Setup.md) | Your laptop | Step-by-step AWS CLI guide to launch the lab server (security group, AMI, user-data). **Out of date:** written for Amazon Linux 2. For OL8, use an Oracle-published OL8 AMI (owner `131827586825`) and pass `user-data-ol8.sh` as user-data. The security group and verification steps are unchanged. |
| [`sync_gateway_4984_tests.md`](sync_gateway_4984_tests.md) | Anywhere that reaches SGW | Manual `curl` tests of the Sync Gateway public API, including channel access control. |
| [`cb-8.0.3-cluster-ol8.sh`](cb-8.0.3-cluster-ol8.sh) | **Every** node of the new cluster | **New environment.** Installs Couchbase Server 8.0.3 and builds a multi-node cluster with the service placement, memory quotas, buckets and RBAC users you configure. **Use this one.** |
| [`cb-certs.sh`](cb-certs.sh) | Your laptop (`generate`); each node (`install`, called by the cluster script) | Optional. Creates a CA and one certificate per node, then installs them in place of Couchbase's self-signed certificates. Removes the "Out-of-the-box certificates are self-signed" warning. |
| [`cb-8.0.3-ol8.sh`](cb-8.0.3-ol8.sh) | One server | Original single-node 8.0.3 install. Tested and working, but superseded: the cluster script with one line in `NODES` does the same job. |
| [`migrate-indexes.sh`](migrate-indexes.sh) | Anywhere that reaches port 9102 on both clusters | Copies index definitions for one bucket from the old cluster to the new one. No data is copied; the new cluster rebuilds the indexes from its own data. |
| [`migrate-sgw-config.py`](migrate-sgw-config.py) | Your laptop or the new SGW server | Converts a Sync Gateway 2.1 `sync_gateway.json` into 4.1 files (`bootstrap.json`, `db-config-*.json`, `users-*.json`). It warns about settings that need a human decision. |
| [`sgw-4.1-ol8.sh`](sgw-4.1-ol8.sh) | A **separate** OL8 server (not a Couchbase node) | Installs Sync Gateway 4.1.1 and configures it from the files that `migrate-sgw-config.py` produced. |

## Order of operations

```
 OLD (untouched)                          NEW
 ───────────────                          ───
 CB 7.0.3 + SGW 2.1  ──(1) lab only──▶  user-data-ol8.sh

                                        (2) cb-8.0.3-cluster-ol8.sh   on every new CB node
 CB 7.0.3 ──────────(3) XDCR──────────▶ CB 8.0.3 cluster
 CB 7.0.3 ──────────(4) migrate-indexes.sh ──▶ CB 8.0.3 cluster
 sync_gateway.json ─(5) migrate-sgw-config.py ──▶ ./migrated/
                                        (6) sgw-4.1-ol8.sh            on the new SGW server
                                        (7) test, then cut clients over
```

1. **Lab only: build the old environment.** Launch an OL8 instance with `user-data-ol8.sh` as user-data, following `EC2_Lab_Setup.md`. At the customer, this step is their existing production environment.
2. **Build the new Couchbase cluster.** See [Building the new cluster](#building-the-new-couchbase-cluster-cb-803-cluster-ol8sh) below.
3. **Start XDCR from old to new.** XDCR is created on the **source** (old) cluster. Set `OLD_CLUSTER_HOST` in the cluster script and re-run it on the bootstrap node, and it prints the exact `xdcr-setup` and `xdcr-replicate` commands to run on the old cluster.
4. **Copy the index definitions** once the bucket exists on the new cluster:
   ```bash
   ./migrate-indexes.sh <old-host> <new-index-node> labdb
   ```
   `<new-index-node>` must be a node that runs the `index` service, because the script talks to port 9102. For credentials other than `Administrator`/`password123`, set `CB_ADMIN_USER` and `CB_ADMIN_PASS`. Run it once per bucket.
5. **Convert the Sync Gateway config** with `migrate-sgw-config.py`.
6. **Install Sync Gateway 4.1** on its own server with `sgw-4.1-ol8.sh`.
7. **Verify, then cut over.**

Steps 5–7 are covered in detail in [Setting up Sync Gateway 4.1](#setting-up-sync-gateway-41-steps-57).

## Building the new Couchbase cluster (`cb-8.0.3-cluster-ol8.sh`)

### Run it on every node

The script does **not** connect to other machines. It installs Couchbase only on the server it runs on. Run the **same file, with the same config**, on every node of the new cluster:

- **First node in `NODES` (the bootstrap node):** installs Couchbase, creates the cluster, rebalances in any nodes that have already joined, then creates the buckets and RBAC users. It **does not wait** for the other nodes.
- **Every other node:** installs Couchbase, waits for the bootstrap node to be initialised (up to `JOIN_TIMEOUT_MIN`, 30 minutes by default), adds itself with the services listed for it, then **rebalances itself in**.

Order doesn't matter, and nodes can run at the same time. If several nodes try to rebalance at once, each one waits for the running rebalance to finish, re-checks and retries. Adding nodes and changing buckets are handled the same way.

### 1. Edit the CONFIG block

Everything you normally change is at the top of the script:

```bash
NODES=(
  "10.0.1.10|data,index,query"   # first line = bootstrap node, must include data
  "10.0.1.11|data"
  "10.0.1.12|index,query"
)
DATA_RAM_MB=2048                 # per-node memory quota for each service
INDEX_RAM_MB=512
FTS_RAM_MB=512
EVENTING_RAM_MB=256
ANALYTICS_RAM_MB=1024

BUCKETS=(                        # name | RAM MB per data node | replicas | couchstore|magma
  "labdb|1024|1|couchstore"
)
USERS=(                          # username | password | roles   ({BUCKETS} = every bucket above)
  "sync_gateway|sgpassword123|bucket_full_access[{BUCKETS}]"
)
```

- **`NODES`:** the address is the DNS name (recommended) or private IP the other nodes use to reach this one. The node registers itself in the cluster under that name, which can't be changed later. See [DNS names for nodes](#dns-names-for-nodes). The available services are `data`, `index`, `query`, `fts`, `eventing`, `analytics` and `backup`.
- **Memory quotas:** these are per node, and apply only on nodes that run that service. The server rejects quotas that don't fit in a node's RAM.
- **Buckets:** the RAM values of all buckets added together must fit within `DATA_RAM_MB`; the script checks this before doing anything. **Magma** buckets are created with 1024 vBuckets, which XDCR from the 7.0.3 cluster needs. Couchstore always has 1024.
- **Storage paths:** `DATA_PATH` (default `/opt/couchbase/var/data`) and `INDEX_PATH` (default `/opt/couchbase/var/index`) are kept separate on purpose. See [Data and index disks](#data-and-index-disks).
- **XDCR hint:** set `OLD_CLUSTER_HOST` to have the script print the XDCR commands to run on the old cluster.

To know the node IPs up front, either launch the instances first and fill in their private IPs, or give them fixed private IPs at launch (`--private-ip-address`).

### Data and index disks

Couchbase recommends a **separate disk for data and for indexes**, so document writes and index builds don't compete for I/O. On EC2, give each node an extra EBS volume for the folder it uses:

| Node runs | Mount a volume at |
|---|---|
| `data` | `DATA_PATH` = `/opt/couchbase/var/data` |
| `index` | `INDEX_PATH` = `/opt/couchbase/var/index` |
| both | two volumes, one at each path |

Mount the volumes **before** the script runs. The paths are **fixed once a node joins a cluster**. Changing them later means removing the node, resetting it and adding it back.

Mount at the data or index folder itself, not at `/opt/couchbase/var`. Couchbase also writes its config and logs under `/opt/couchbase/var`, so a volume mounted there would hold the logs too and could fill up.

Example for OL8 on Nitro instances. Check the device name with `lsblk` first. It's safe to re-run:

```bash
DEV=/dev/nvme1n1
MNT=/opt/couchbase/var/data        # on index nodes: /opt/couchbase/var/index

sudo blkid "$DEV" || sudo mkfs.xfs "$DEV"     # formats ONLY if the volume is blank
sudo mkdir -p "$MNT"
grep -q " $MNT " /etc/fstab || \
  echo "UUID=$(sudo blkid -s UUID -o value "$DEV") $MNT xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a
df -h "$MNT"                                   # should show the new volume
```

For a node that runs both data and index, repeat with a second volume (for example `/dev/nvme2n1`) at `/opt/couchbase/var/index`. To do this with user-data, put these lines ahead of the cluster script. The script sets the folder owner to `couchbase` after installing, so there's no need to `chown` here.

Size each volume for data growth plus compaction headroom. Couchstore compaction can briefly need up to twice a bucket's on-disk size.

If a node's volume isn't mounted, the script still works: it creates the folder on the root disk and warns. That's fine for a lab. In production, treat that warning as a stop.

### DNS names for nodes

**Best practice: use DNS names in `NODES`, not IPs.** A node joins the cluster under its `NODES` address, and Couchbase requires the node's certificate to name that same address. DNS names therefore give you:
- **Certificates with DNS names** (`DNS:cb-data-1.securus.internal`) rather than IPs, which is what clients and corporate PKIs expect.
- **Stable client configuration.** Sync Gateway, SDKs and XDCR connect by name. A replaced node can take over its name by updating one DNS record.

**Recommended: a Route 53 private hosted zone** attached to the cluster's VPC. The names resolve only inside that VPC:

```bash
VPC_ID=<the nodes' VPC id>; REGION=<region>
ZONE_ID=$(aws route53 create-hosted-zone --name securus.internal \
  --vpc VPCRegion=$REGION,VPCId=$VPC_ID --caller-reference "cb-$(date +%s)" \
  --hosted-zone-config PrivateZone=true --query 'HostedZone.Id' --output text)

# One A record per node -> its private IP
add_record() { aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch \
  "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$1\",\"Type\":\"A\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$2\"}]}}]}"; }
add_record cb-data-1.securus.internal  172.31.9.252
add_record cb-data-2.securus.internal  172.31.11.13
add_record cb-data-3.securus.internal  172.31.10.84
add_record cb-index-1.securus.internal 172.31.15.8
add_record cb-index-2.securus.internal 172.31.14.193
```

The VPC must have **DNS resolution** and **DNS hostnames** enabled, which is the default for the default VPC. If Securus has its own internal DNS, create the same A records there instead. The domain name above is an example.

Then use the names in the cluster script:

```bash
NODES=(
  "cb-data-1.securus.internal|data"
  "cb-data-2.securus.internal|data"
  "cb-data-3.securus.internal|data"
  "cb-index-1.securus.internal|index,query"
  "cb-index-2.securus.internal|index,query"
)
```

How the scripts handle names:
- **Resolution check:** each node checks that every name in `NODES` resolves before doing anything else, and stops with the list of names that don't.
- **Finding itself:** a node recognises its own entry by resolving each name and comparing the result with its own IPs. `THIS_NODE` isn't needed.
- **Certificates:** `./cb-certs.sh generate` issues certificates with a DNS SAN for each name, and warns about any entry that is still an IP.

**Moving an existing IP-based cluster to names.** A node's name can't be changed after it joins, so each node has to leave the cluster and join again under its name.
- **Test cluster:** rebuild it. On every node, stop and remove Couchbase, then clear the data and index folders but keep the mounted volumes:
  ```bash
  sudo systemctl stop couchbase-server
  sudo dnf remove -y couchbase-server
  sudo find /opt/couchbase/var/data /opt/couchbase/var/index -mindepth 1 -delete 2>/dev/null
  sudo rm -rf /opt/couchbase/var/lib/couchbase
  ```
  Then switch `NODES` to names, regenerate the certificates, and run the script on every node, bootstrap first.
- **Cluster holding data you want to keep:** swap one node at a time. Remove it in the console and rebalance, clean it up as above, then re-run the script with its `NODES` line changed to its name, so it joins and rebalances itself back in. The bootstrap node must also be swapped; do it last, after pointing `NODES` line 1 at a node that already uses its name.

### Private vs public IPs

Use **private DNS names** (preferred) or **private IPs** for anything inside the VPC, never public IPs. From your laptop, reach the Web Console through an SSH tunnel. See [Opening the Web Console](#opening-the-web-console).

| What | Address to use | Why |
|---|---|---|
| `NODES` in the cluster script | Private DNS name, or private IP | A node's address is fixed once it joins. A public IP changes when the instance is stopped and started, and node-to-node traffic would leave the VPC. |
| XDCR target, `migrate-indexes.sh`, `--new-cb-host` for Sync Gateway | Private IP | Same VPC, no internet round trip, no public ports needed. |
| Web Console from your laptop | SSH tunnel to any node's public IP, then `http://localhost:8091` | Works reliably, and 8091 doesn't need to be open to the internet. The console only talks to the node you open it on, which reaches the other nodes itself. |
| SDK or app clients **outside** the VPC | See the note below | The cluster map tells clients to use the nodes' private IPs, which they can't reach. |

Clients outside the VPC connect to the node you give them, receive the private IPs of every node, and then fail with timeouts. The fixes are to run clients inside the VPC (or over VPN or peering), or to set public [alternate addresses](https://docs.couchbase.com/server/current/learn/clusters-and-availability/connectivity.html#alternate-addresses) on each node with `couchbase-cli setting-alternate-address`. The Web Console doesn't need either.

### Opening the Web Console

Open the console through an **SSH tunnel**, not by browsing to the node's public IP:

```bash
ssh -i <key.pem> -L 8091:localhost:8091 ec2-user@<any-node-public-ip>
# leave this running, then open http://localhost:8091 in a private/incognito window
```

Any node works, because each one serves the console for the whole cluster. The tunnel only needs port 22 open to you, so 8091 can stay closed to the internet.

**Why not the public IP?** In testing, `http://<public-ip>:8091` showed the login page but the console never got past it, even though the REST API on the same address worked (`curl -u Administrator:<pass> http://<public-ip>:8091/pools/default` returned the cluster). The same console worked straight away through the tunnel. The usual cause is a VPN, proxy or browser extension on the laptop interfering with the console's session cookie or its long-running requests. The cluster itself is fine.

If the console fails even through the tunnel, clear the browser's site data for `localhost:8091`. Then check the Network tab (F12) for the first request that fails or stays pending.

### 2. Network: inbound rules

This is the **single reference** for every port the migration uses. Two security groups are involved:
- **`<cb-sg>`**: the Couchbase nodes' group.
- **`<sgw-sg>`**: the Sync Gateway server's group.

When a table says the source is a group, set Source to **Custom** in the console and pick that group (`sg-…`). The rule then covers every instance in the group, and keeps working when IPs change.

#### Couchbase Server ports

| HTTP / plain | HTTPS / TLS | Service | Who connects | This cluster |
|---|---|---|---|---|
| 8091–8097 | 18091–18097 | Service REST APIs: 8091 management and Web Console, 8092 views/XDCR, 8093 query, 8094 search, 8095 analytics, 8096 eventing, 8097 backup | Nodes, Sync Gateway, SDKs, old cluster (XDCR), admins | **Yes** |
| 9100–9105 | 19102 (for 9102) | Index service: admin, scan, HTTP (9102), streams | Nodes; 9102 also from the `migrate-indexes.sh` host | **Yes** |
| 9110–9118 | same port | Analytics, internal | Nodes only | Only with analytics |
| 9120–9124 | same port | 9120–9122 analytics, 9123 stats (Prometheus), 9124 backup | Nodes only | **Yes** (9123) |
| 9130 | 19130 | Search (fts) gRPC | Nodes only | Only with fts |
| 9140 | same port | Eventing debugger | Admins | Only with eventing |
| 9999 | same port | Index projector, on the data nodes | Nodes only | **Yes** |
| 11209–11210 | 11207 | Data service (KV): 11210 clients, 11209 internal | Nodes, Sync Gateway, SDKs, old cluster (XDCR) | **Yes** |
| 11280 | same port | Data service, internal | Nodes only | **Yes** |
| 21100, 21150, 21200, 21300 | same port | Internal cluster communication | Nodes only | **Yes** |
| 4369 | same port | Erlang port mapper (legacy) | Nodes only | Harmless to open |

**All Couchbase ports as ranges**, for a security group or firewall:

```
4369, 8091-8097, 9100-9105, 9110-9118, 9120-9124, 9130, 9140, 9999,
11207-11210, 11280, 18091-18097, 19102, 19130, 21100, 21150, 21200, 21300
```

11207–11210 covers the data service's TLS port (11207) and plain ports (11209–11210) in one range. 11208 isn't used by Couchbase, so including it is harmless.

"Same port" means the traffic stays on that port and is encrypted when [node-to-node encryption](https://docs.couchbase.com/server/current/manage/manage-security/manage-node-to-node-encryption.html) is turned on.

Ports can change between Couchbase versions. Check the [network ports reference](https://docs.couchbase.com/server/current/install/install-ports.html) when upgrading.

#### Sync Gateway ports

Sync Gateway serves HTTP and HTTPS on the **same** port. It switches to HTTPS once a TLS certificate is set in its bootstrap config.

| HTTP | HTTPS | Service | Who connects |
|---|---|---|---|
| 4984 | 4984 | Public REST API | Mobile or app clients |
| 4985 | 4985 | Admin REST API. **Never public.** | Admins, provisioning scripts |
| 4986 | 4986 | Metrics (Prometheus) | Monitoring |

Sync Gateway connects **out** to Couchbase on 8091, 8093 and 11210. With `couchbases://` it uses 18091, 18093 and 11207 instead. These are rules on `<cb-sg>`, listed below.

#### Rules to create

**On `<cb-sg>`, the Couchbase nodes:**

| Type | Port(s) | Source | Why |
|---|---|---|---|
| All TCP | 0–65535 | `<cb-sg>` | Node-to-node: every port marked "Nodes" above. **Required.** |
| SSH | 22 | your IP (`x.x.x.x/32`) | SSH and the [console tunnel](#opening-the-web-console). **Required.** |
| Custom TCP | 8091, 8093, 11210 (TLS: 18091, 18093, 11207) | `<sgw-sg>` | Sync Gateway → Couchbase |
| Custom TCP | 8091, 8092, 11210 (TLS: 18091, 18092, 11207) | old cluster's group or IPs | XDCR from 7.0.3 |
| Custom TCP | 9102 (TLS: 19102) | host running `migrate-indexes.sh` | Index migration. The old cluster's index node needs this too. |

If you'd rather not use All TCP between nodes, open every port marked "Nodes" in the Couchbase table, from `<cb-sg>`. A missed port fails in confusing ways. If `<cb-sg>` is shared with non-Couchbase instances, give the Couchbase nodes a dedicated group so the All TCP rule stays within the cluster.

**On `<sgw-sg>`, the Sync Gateway server:**

| Type | Port | Source | Why |
|---|---|---|---|
| Custom TCP | 4984 | app clients (or `0.0.0.0/0` if the apps are public) | Public API |
| Custom TCP | 4985 | admin IPs only | Admin API |
| Custom TCP | 4986 | monitoring IPs only | Metrics |
| SSH | 22 | your IP | SSH |

**Symptoms of a missing port:**
- **Join fails with `Failed to reach otp port 21100`:** 21100 is blocked between nodes.
- **Join fails with `http is prohibited`, or times out:** 18091 is blocked to the joining node.
- **Adding an index/query node hangs in rebalance:** 9100–9105 or 9999 is blocked.
- **Sync Gateway can't reach the bucket:** 11210 (or 11207) from `<sgw-sg>` is missing.

#### AWS CLI

```bash
CB_SG=<couchbase nodes security group id>
SGW_SG=<sync gateway security group id>

# Node-to-node, and SSH from your current IP
aws ec2 authorize-security-group-ingress --group-id "$CB_SG" --protocol tcp --port 0-65535 --source-group "$CB_SG"
aws ec2 authorize-security-group-ingress --group-id "$CB_SG" --protocol tcp --port 22 --cidr "$(curl -s https://checkip.amazonaws.com)/32"

# Sync Gateway -> Couchbase (add 18091 18093 11207 if using couchbases://)
for p in 8091 8093 11210; do
  aws ec2 authorize-security-group-ingress --group-id "$CB_SG" --protocol tcp --port "$p" --source-group "$SGW_SG"
done
```

If `firewalld` is running on a node, the cluster script opens the node-to-node ports on the node itself. The security group rules are still needed. Before joining, each node checks that it can reach the bootstrap node on 8091, 18091 and 21100, and stops with a clear error if it can't.

### 3. Run it

**As EC2 user-data**, the easiest option: pass the same edited script as user-data to every instance. Each one works out its own role at boot.

**By hand**: copy the script to each node, then run:

```bash
sudo bash cb-8.0.3-cluster-ol8.sh
```

If a node can't find itself in `NODES` (for example because of DNS naming), tell it which entry it is:

```bash
sudo THIS_NODE=10.0.1.11 bash cb-8.0.3-cluster-ol8.sh
```

### 4. Check the result

- **Log:** `/var/log/cb-8.0.3-cluster-install.log` on each node. The bootstrap node's log ends with the list of cluster members.
- **Summary:** `/home/ec2-user/CB_8.0.3_CLUSTER_READY.txt` on the bootstrap node.
- **Web Console:** open it [through an SSH tunnel](#opening-the-web-console), then go to **Servers** to confirm every node is listed with the services you configured.

### CA-signed certificates (optional)

Out of the box, every node uses a self-signed certificate, and the console warns *"Out-of-the-box certificates are self-signed"*. Traffic is still encrypted. What's missing is proof of identity: clients and other nodes can't verify which node they're talking to. [`cb-certs.sh`](cb-certs.sh) replaces those certificates with ones signed by a CA.

**1. On your laptop, create the CA and node certificates.** Node addresses are read from `NODES` in the cluster script. The output folder is `CERT_DIR` in the same script (default `certs`, next to the scripts), so there's one setting for both scripts:

```bash
./cb-certs.sh generate
```

This creates:

```
ca/ca.key, ca/ca.pem            ← the CA. Keep it on your laptop. Never copy ca/ to a node.
certs/ca.pem                    ← the CA certificate, for nodes and clients
certs/<node-ip>/chain.pem       ← one certificate + key per node
certs/<node-ip>/pkey.key
certs.tar.gz                    ← certs/ packed into one file, ready to copy to the nodes
```

`certs.tar.gz` is rebuilt on every run, so it always matches `certs/`. The output lists the node certificates in it. `generate` also warns about any folder under `certs/` that no longer matches a `NODES` entry.

It's safe to re-run. Existing valid certificates are kept. Only missing ones, ones expiring within 30 days, or ones not matching the CA or address are issued. Node certificates last **10 years** and the CA **20 years**, so every node certificate expires before the CA that signed it. Two things to know:
- **Existing certificates keep their old lifetime.** A re-run of `generate` doesn't re-issue a certificate just because the lifetime setting changed. To re-issue them, delete the node folders under `certs/` (not `ca/`) and run `generate` again.
- **Apple devices may not trust the console over HTTPS.** macOS and iOS reject TLS server certificates valid for more than 825 days. That affects Safari, and Chrome on a Mac, when opening the console over HTTPS on 18091. It doesn't affect node-to-node traffic, Sync Gateway, SDKs or XDCR, and the SSH tunnel to `http://localhost:8091` still works. If people need HTTPS console access from Macs, set `NODE_DAYS=825` in `cb-certs.sh`.

**Where to run `generate`:** your laptop, or a Linux admin or bastion host. Put `cb-certs.sh` and `cb-8.0.3-cluster-ol8.sh` in the same folder; only `openssl` is needed. Avoid running it on a cluster node in production, because whichever machine runs it holds the CA private key.

**Back up `ca/`.** It holds the CA key and certificate, and you'll need it again to add nodes or renew certificates. Keep an encrypted copy, for example in a password manager, AWS Secrets Manager or an encrypted S3 bucket. If `certs/ca.pem` exists but `ca/` is missing, `generate` refuses to create a new CA, because that would invalidate every node certificate already issued.

**2. Copy the scripts and `certs/` to every node.** Each node installs **its own** certificate when the cluster script runs, so the files must be on that node, next to the cluster script. Copying the whole `certs/` folder everywhere is simplest; each node uses only `certs/ca.pem` and `certs/<its-address>/`. Never copy `ca/`.

```bash
# node public IPs, or names you can SSH to
for h in <node1> <node2> <node3> <node4> <node5>; do
  scp -i <key.pem> -r cb-8.0.3-cluster-ol8.sh cb-certs.sh certs ec2-user@"$h":~/
done
```

**Or copy one archive instead of the folder.** Copy the `certs.tar.gz` that `generate` created (or your own `certs.zip`) next to the cluster script. If `certs/` is missing, the script unpacks it, using `tar` or `unzip` (installing `unzip` if needed). It also accepts `cert.tar.gz`, `cert.tgz` or `cert.zip`, and archives with the files at the top level instead of inside a `certs/` folder. An existing `certs/` folder is never overwritten.

Keep the files on the nodes after installing. With `CUSTOM_CERTS="true"`, every re-run checks them to confirm the node is serving the right certificate.

**3. Set `CUSTOM_CERTS="true"`** in the cluster script and run it on every node, bootstrap node first. Each node installs its certificate before it joins. The bootstrap node installs its own right after creating the cluster, so the cluster trusts the CA before the others join.

**For an existing cluster**, the same steps work. Re-run the script on the bootstrap node, then on each of the other nodes. A node that is already serving the right certificate is skipped. The script checks what the node actually serves on port 18091, not just the files.

**With your own PKI** (for example Securus's corporate CA or AWS Private CA), skip step 1. Put the files in the same layout: `certs/ca.pem`, and `certs/<node-ip>/chain.pem` plus `certs/<node-ip>/pkey.key` for each node. The certificate must list the node's `NODES` address as a subject alternative name (`IP:172.31.x.x`), and the key must not be password-protected. `ca/` isn't needed.

**Clients** that should verify the cluster need `certs/ca.pem`: Sync Gateway with `couchbases://`, SDKs, and the old cluster for encrypted XDCR (`--xdcr-secure-connection full --xdcr-certificate ca.pem`).

**With EC2 user-data**, the `certs/` folder isn't on the instance. Either run the script by hand after copying the files, or have the user-data download `cb-certs.sh` and `certs/` (for example from a private S3 bucket) before it runs the cluster script.

### Changing a running cluster

Once the cluster is in service, make changes through the same script and settings rather than by hand, so the script stays an accurate record of the cluster. Some changes aren't automated and are marked below.

| You want to… | Do this |
|---|---|
| Add a node | Add its line to `NODES` and run the script on the new node. It joins and rebalances itself in. With `CUSTOM_CERTS="true"`, first re-run `./cb-certs.sh generate` and copy `certs/` to the new node. |
| Renew certificates | Re-run `./cb-certs.sh generate`, which re-issues any within 30 days of expiry. Copy `certs/` to the nodes and re-run the cluster script on each. |
| Change memory quotas or bucket RAM | Edit the values and re-run on the bootstrap node. |
| Add a bucket or user | Add its line and re-run on the bootstrap node. |
| Change bucket replicas or backend | **Not automatic.** Change it in the Web Console or with `couchbase-cli bucket-edit`, then rebalance. The script only keeps bucket RAM in sync. |
| Remove a node | **Not automatic.** Remove it in the Web Console and rebalance, then delete its line from `NODES`. |

## Setting up Sync Gateway 4.1 (steps 5–7)

Do this once the new Couchbase cluster is up. Sync Gateway runs on its **own** OL8 server, not on a Couchbase node, and connects to the cluster over the network.

### Before you start

| Check | How |
|---|---|
| The cluster has the bucket and the Sync Gateway RBAC user | The cluster script creates both from `BUCKETS` and `USERS`: every bucket in `BUCKETS`, and `sync_gateway` / `sgpassword123` with `bucket_full_access` on each of them (`bucket_full_access[{BUCKETS}]`). Check under **Security** and **Buckets** in the console. |
| An OL8 instance for Sync Gateway, in the **same VPC** | For example `t3.medium`. It must resolve the nodes' private DNS names, which it can if it's in the same VPC. |
| Network rules | On the **Couchbase** security group: allow 8091, 8093 and 11210 from the Sync Gateway server's group. On the **Sync Gateway** group: 4984 for apps, and 22 from your IP. See [Network: inbound rules](#2-network-inbound-rules). |
| The old Sync Gateway 2.1 config | In the lab it's `/opt/sync_gateway/etc/sync_gateway.json` on the old server. Copy it off, for example: `scp -i <key.pem> ec2-user@<old-sgw>:/opt/sync_gateway/etc/sync_gateway.json ./old-sync_gateway.json`. It's root-owned, so `sudo cp` it to your home folder first if `scp` is refused. |
| Data and indexes on the new cluster (recommended) | Run step 3 (XDCR) and step 4 (`migrate-indexes.sh`) first, so the migrated documents are there when Sync Gateway starts. Otherwise Sync Gateway starts on an empty bucket. |

### Step 5: convert the config (`migrate-sgw-config.py`)

Run this on your laptop or on the Sync Gateway server; it only needs `python3`. For `--new-cb-host`, give **one** node's private DNS name, preferably a data node. Sync Gateway discovers the rest of the cluster from it.

```bash
python3 migrate-sgw-config.py --input ./old-sync_gateway.json \
  --new-cb-host ip-172-31-3-230.us-west-1.compute.internal \
  --new-cb-user sync_gateway --new-cb-password sgpassword123 \
  --output-dir ./migrated
```

It writes:

| File | What it is |
|---|---|
| `migrated/bootstrap.json` | Node-level config: the cluster address (`couchbase://<host>`), the RBAC user, and the API ports. The Admin API listens on `127.0.0.1:4985` only (loopback) by default; change that with `--admin-interface`. |
| `migrated/db-config-<db>.json` | One per database: bucket, sync function, and `enable_shared_bucket_access: true`, which 4.x requires. |
| `migrated/users-<db>.json` | The database's users, if the old config had any. |

**Read every warning it prints** before going further:
- **`shared_bucket_access` was not true in the source:** the old Sync Gateway stored its metadata inside documents. This is a data migration concern, not just a setting. Test with real data first.
- **`allow_conflicts` or `enable_star_channel` dropped:** 4.x doesn't support them, and they would stop the database from starting.
- **`use_views`, or Facebook/Google login:** flagged, not converted. Views need GSI indexes instead. Social login needs a move to OIDC or custom auth, which app teams will notice.

### Step 6: install Sync Gateway (`sgw-4.1-ol8.sh`)

1. **Check the credentials** at the top of `sgw-4.1-ol8.sh`. `CB_ADMIN_USER` and `CB_ADMIN_PASS` (default `Administrator` / `password123`) must match the cluster's admin user, because the script uses them to call Sync Gateway's Admin API.
2. **Copy the script and `migrated/`** to the Sync Gateway server:
   ```bash
   scp -i <key.pem> -r sgw-4.1-ol8.sh migrated ec2-user@<sgw-server>:~/
   ```
3. **Run it** on the Sync Gateway server:
   ```bash
   sudo bash sgw-4.1-ol8.sh ./migrated
   ```

The script:
1. checks that Couchbase is reachable on 8091 at the host in `bootstrap.json`
2. installs Sync Gateway 4.1.1
3. finds the config path this package actually uses
4. installs `bootstrap.json` there and starts the service cleanly
5. creates each database from `db-config-*.json` and waits for it to come online
6. creates the users from `users-*.json`

It's safe to re-run: an existing Sync Gateway install or database is skipped. That also means a **changed** `db-config-*.json` is not applied to a database that already exists. To change one, update it through the Admin API (`PUT /<db>/_config`), or delete the database and re-run.

- **Log:** `/var/log/sgw-4.1-install.log`
- **Summary:** `/home/ec2-user/SGW_4.1_READY.txt`

### Step 7: verify, then cut over

On the Sync Gateway server:

```bash
curl -s http://localhost:4984/                                         # expect "version":"4.1..."
curl -s -u Administrator:password123 http://localhost:4985/labdb/      # expect "state":"Online"
curl -s -u Administrator:password123 http://localhost:4985/labdb/_all_docs?limit=5
```

Then run the tests in [`sync_gateway_4984_tests.md`](sync_gateway_4984_tests.md) against the new server, with these adjustments:
- **Host:** use the new server's address.
- **Version:** expect `4.1` wherever the tests expect `2.1`.
- **Admin API:** it now needs a username and password (`-u`), and it's on loopback only, so run admin checks on the Sync Gateway server itself.

The user tests (alice, bob and carol) only pass once their documents have arrived through XDCR.

**Cutover, in outline:**
1. Freeze or drain writes through the old Sync Gateway.
2. Confirm XDCR has caught up: the replication's *changes left* is 0 on the old cluster.
3. Point clients at the new Sync Gateway on 4984.
4. Keep the old environment running, untouched, as the rollback path until you're confident.

### Known gaps

- **Connections to Couchbase aren't encrypted yet.** Even with `CUSTOM_CERTS="true"`, the generated `bootstrap.json` uses `couchbase://` and `"use_tls_server": false`. To connect over TLS, edit `bootstrap.json`: set `"server": "couchbases://<node>"`, add `"ca_cert_path"` pointing to a copy of `certs/ca.pem` on the Sync Gateway server, and open 18091, 18093 and 11207 instead of the plain ports.
- **Passwords are in the files.** `sgw-4.1-ol8.sh` and `bootstrap.json` contain plain-text credentials. Change them for anything beyond the lab, and restrict who can read the files.

## Things to know before production use

- **Credentials:** every script contains lab passwords (`password123`, `sgpassword123`). Change them in each script's config section before running anywhere real, and keep the changed copies out of shared locations.
- **Same credentials everywhere:** the admin credentials must match across `cb-8.0.3-cluster-ol8.sh`, `sgw-4.1-ol8.sh` (`CB_ADMIN_*`) and `migrate-indexes.sh` (`CB_ADMIN_*` env vars).
- **CPU:** Couchbase Server 8.0 needs a CPU with **AVX2**. The install scripts refuse to continue without it. Current-generation EC2 types have it.
- **Unencrypted transport:** the scripts use HTTP on 8091 and XDCR without TLS (`--xdcr-secure-connection none`). That's fine for a lab. Decide on TLS before production.
