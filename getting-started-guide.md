# Getting started: Couchbase 8.0.3 cluster, Sync Gateway 4.1 cluster, index migration

This guide walks through the scripts in this folder, in the order you run them:

1. **[Part 1](#part-1-couchbase-server-803-cluster):** build a multi-node Couchbase Server 8.0.3 cluster with `cb-8.0.3-cluster-ol8.sh` (and `cb-certs.sh` for certificates).
2. **[Part 2](#part-2-sync-gateway-41-cluster):** build a multi-node Sync Gateway 4.1 cluster with `migrate-sgw-config.py` and `sgw-4.1-ol8.sh`.
3. **[Part 3](#part-3-migrate-the-indexes):** copy the index definitions from the old cluster with `migrate-indexes.sh`.

The scripts do the work themselves. Each one needs only a few inputs, set at the top of the script or on the command line. Each one checks its own prerequisites and stops with a clear `ERROR:` if something is missing. Every script is **safe to re-run**: if a run fails, fix the cause and run the same command again.

For the design behind each step, see [README.md](README.md).

---

## The scripts at a glance

| Script | Where you run it | What you give it |
|---|---|---|
| `cb-certs.sh generate` | Your laptop or admin machine (needs `openssl`) | Nothing. It reads `NODES` and `CERT_DIR` from the cluster script in the same folder. |
| `cb-8.0.3-cluster-ol8.sh` | **Every** new Couchbase VM (the same file, unchanged) | The `CONFIG` block at the top of the script. |
| `migrate-sgw-config.py` | Your laptop (needs `python3`) | The old `sync_gateway.json`, one new Couchbase node address, and the Sync Gateway user and password. |
| `sgw-4.1-ol8.sh` | **Every** new Sync Gateway VM | `CB_ADMIN_USER` / `CB_ADMIN_PASS` at the top of the script, plus the `migrated/` folder. |
| `migrate-indexes.sh` | Any machine that reaches port 9102 on both clusters (for example, a new index node) | Old host, new index host, bucket name, and the admin login as environment variables. |

**Credentials must match across the kit.** Use the same Couchbase admin username and password in:

- `ADMIN_USER` / `ADMIN_PASS` in `cb-8.0.3-cluster-ol8.sh`
- `CB_ADMIN_USER` / `CB_ADMIN_PASS` in `sgw-4.1-ol8.sh`
- the `CB_ADMIN_USER` / `CB_ADMIN_PASS` environment variables for `migrate-indexes.sh`

`migrate-indexes.sh`, and the XDCR commands the cluster script prints, use that one login on **both** the old and the new cluster.

---

## Before you start

**VMs**

| Role | Count (example) | Notes |
|---|---|---|
| Couchbase node | 3 or more | Oracle Linux 8. **The CPU must have AVX2**: the script stops without it. On VMware, check that the cluster's EVC mode doesn't hide AVX2. |
| Sync Gateway node | 2 or more | Oracle Linux 8. These must be **separate VMs**, not Couchbase nodes. |
| Load balancer | 1 | Your existing load balancer, in front of the Sync Gateway nodes. |

Each VM needs a user with `sudo`, and access to the OS package repos and `packages.couchbase.com`. The scripts download the RPMs and run `dnf`.

**Network.** The Couchbase nodes must reach each other on all Couchbase ports. If `firewalld` is running on a node, the cluster script opens the ports on that node itself. Any **network** firewall between the VMs needs the rules in [README: Network: inbound rules](README.md#2-network-inbound-rules). In short:

| From | To | Ports |
|---|---|---|
| Couchbase nodes | each other | all TCP (or the full list in the README) |
| Sync Gateway nodes | Couchbase nodes | 8091, 8093, 11210 |
| Old Couchbase cluster | new Couchbase nodes | 8091, 8092, 11210 (XDCR) |
| Machine running `migrate-indexes.sh` | old and new index nodes | 9102 (and 8093 on the new node, for the final check) |
| Load balancer / apps | Sync Gateway nodes | 4984 |

**Node addresses.** Decide the address of each Couchbase node now: a **DNS name** (recommended) or a fixed private IP. A node joins the cluster under that address, its certificate is issued for it, and it **can't be changed later**. Every node must be able to resolve every name. See [README: DNS names for nodes](README.md#dns-names-for-nodes).

**On your laptop**, put all the scripts in one folder and work from there:

```bash
cd cb-upgrade        # the folder with cb-8.0.3-cluster-ol8.sh, cb-certs.sh, sgw-4.1-ol8.sh, ...
```

---

## Part 1: Couchbase Server 8.0.3 cluster

### Step 1.1: Fill in the CONFIG block

Open `cb-8.0.3-cluster-ol8.sh` and edit **only** the block between `CONFIG - EDIT HERE` and `END CONFIG`. Nothing below it needs changing.

```bash
CB_VERSION="8.0.3"
CLUSTER_NAME="prod-8.0.3"
ADMIN_USER="Administrator"
ADMIN_PASS="<strong-password>"

NODES=(
  "cb-data-1.example.internal|data"           # FIRST line = bootstrap node, must include data
  "cb-data-2.example.internal|data"
  "cb-data-3.example.internal|data"
  "cb-index-1.example.internal|index,query"
  "cb-index-2.example.internal|index,query"
)

DATA_RAM_MB=8192          # per node, for each service it runs
INDEX_RAM_MB=8192
FTS_RAM_MB=512            # ignored unless a node runs fts
EVENTING_RAM_MB=256       # ignored unless a node runs eventing
ANALYTICS_RAM_MB=1024     # ignored unless a node runs analytics
INDEX_STORAGE="default"

BUCKETS=(                 # name | RAM MB per data node | replicas | couchstore or magma
  "threads|4096|1|couchstore"
  "orders|2048|1|couchstore"      # one line per bucket; add or remove lines as needed
)

USERS=(                   # username | password | roles   (Sync Gateway logs in as this user)
  "sync_gateway|<sgw-password>|bucket_full_access[{BUCKETS}]"
)

DATA_PATH="/opt/couchbase/var/data"
INDEX_PATH="/opt/couchbase/var/index"
JOIN_TIMEOUT_MIN=30
OLD_CLUSTER_HOST=""       # set in step 1.6 to get the XDCR commands
CUSTOM_CERTS="true"       # "false" to keep Couchbase's self-signed certificates (skip step 1.2)
CERT_DIR="certs"
```

| Setting | What to put |
|---|---|
| `ADMIN_USER` / `ADMIN_PASS` | The cluster admin login. Keep it the **same as the old cluster's** admin login, so `migrate-indexes.sh` and the printed XDCR commands work against both. Avoid `"`, `$` and `` ` `` in the password. |
| `NODES` | One line per Couchbase VM: `"<address>\|<services>"`. Services: `data,index,query,fts,eventing,analytics,backup`. The **first line is the bootstrap node** and must include `data`. |
| `*_RAM_MB` | The memory quota per node for each service. The server rejects quotas that don't fit the node's RAM. |
| `BUCKETS` | Use the **same bucket names as the old cluster**. The RAM values of all buckets added together must fit in `DATA_RAM_MB`; the script checks this before it starts. Magma buckets are created with 1024 vBuckets, so XDCR from 7.0.3 works. |
| `USERS` | The RBAC user Sync Gateway connects as. You use the same name and password in step 2.2. **Leave the role as `bucket_full_access[{BUCKETS}]`**: `{BUCKETS}` expands to one role per bucket in `BUCKETS`, so the user gets every bucket, one or many, and keeps up if you rename or add buckets. To limit the user to some buckets, name them instead: `bucket_full_access[threads],bucket_full_access[orders]`. The script stops before installing if a role names a bucket that isn't in `BUCKETS`. |
| `DATA_PATH` / `INDEX_PATH` | Leave as is. Mount a separate disk at each one (step 1.3). |
| `CUSTOM_CERTS` | `"true"` installs your own CA-signed certificates (step 1.2). `"false"` keeps the self-signed ones. |

Check what you entered. This prints the node addresses exactly as the script reads them; it's safe to run on your laptop:

```bash
bash cb-8.0.3-cluster-ol8.sh --print-nodes
```

### Step 1.2: Create the node certificates on your laptop

Skip this step if `CUSTOM_CERTS="false"`.

**Run this on your laptop, in the same folder as the cluster script, after `NODES` is final.** `cb-certs.sh` reads `NODES` and `CERT_DIR` from the cluster script:

```bash
./cb-certs.sh generate
```

It creates:

```
ca/ca.key, ca/ca.pem            ← the CA. Stays on your laptop. Never copy ca/ to a node.
certs/ca.pem                    ← CA certificate, for the nodes and for clients
certs/<node-address>/chain.pem  ← one certificate + key per NODES entry
certs/<node-address>/pkey.key
certs.tar.gz                    ← the certs/ folder packed into one file. This is what you copy to the nodes.
```

It ends by listing the node certificates inside `certs.tar.gz`. **Check that the list matches your `NODES` exactly.** The cluster script unpacks `certs.tar.gz` itself on each node.

Then **back up `ca/`** somewhere safe, such as a password manager or secrets vault. You need it again to add a node or renew certificates. If `ca/` is lost, `generate` refuses to create a new CA while `certs/` exists, because a new CA would invalidate every certificate already issued.

Notes:

- **Re-running `generate` is safe.** Valid certificates are kept, and only missing, expiring or mismatched ones are issued. `certs.tar.gz` is rebuilt on every run. Run it again whenever `NODES` changes.
- **`WARNING: certs/<address> is not in the node list`** means a folder is left over from a node that's no longer in `NODES`, for example after replacing VMs. Delete that folder (`rm -rf certs/<address>`) and re-run `generate`, so the archive holds only current nodes.
- **Using your own PKI** (a corporate CA)? Skip `generate`. Lay out the files the same way: `certs/ca.pem`, plus `certs/<node-address>/chain.pem` and `certs/<node-address>/pkey.key` per node. Each certificate must name the node's `NODES` address, and the key must be unencrypted. See [README: CA-signed certificates](README.md#ca-signed-certificates-optional).
- **If a node is listed by IP address,** `generate` warns about it: that node's certificate names the IP. It works, but DNS names are recommended.

### Step 1.3: (Recommended) Mount the data and index disks

Couchbase recommends a separate disk for data and for indexes. Mount them **before** the first run, because the paths are fixed once a node joins the cluster. On each Couchbase VM that has an extra disk, run:

```bash
lsblk                                   # find the empty disk, e.g. /dev/sdb or /dev/nvme1n1
DEV=/dev/sdb                            # the empty disk
MNT=/opt/couchbase/var/data             # on index nodes: /opt/couchbase/var/index

sudo blkid "$DEV" || sudo mkfs.xfs "$DEV"     # formats ONLY if the disk is blank
sudo mkdir -p "$MNT"
grep -q " $MNT " /etc/fstab || \
  echo "UUID=$(sudo blkid -s UUID -o value "$DEV") $MNT xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a
df -h "$MNT"                            # should show the new disk
```

A node that runs both data and index needs two disks: repeat with the second disk at `/opt/couchbase/var/index`. If you skip this, the script still works, but it warns that the folder is on the root disk. That's fine for a test; for production, treat the warning as a stop. More detail: [README: Data and index disks](README.md#data-and-index-disks).

### Step 1.4: Copy the files to every Couchbase node

**What goes to each node.** Every node gets the same three files, in the **same folder** (the SSH user's home folder):

| File | Needed when | Why |
|---|---|---|
| `cb-8.0.3-cluster-ol8.sh` | always | The installer. It must be the copy you edited in step 1.1. |
| `cb-certs.sh` | `CUSTOM_CERTS="true"` | The cluster script calls it to install the node's certificate. |
| `certs.tar.gz` | `CUSTOM_CERTS="true"` | Holds the certificates from step 1.2. The cluster script unpacks it itself. |

**Never copy `ca/`.** It holds the CA private key and stays on your laptop.

**a) Check the files on your laptop before copying.** Run this in the folder holding the scripts:

```bash
bash cb-8.0.3-cluster-ol8.sh --print-nodes      # must be your final node list
tar -tzf certs.tar.gz | grep chain.pem          # one line per node above, same addresses
chmod 600 certs.tar.gz                          # you must be able to read it; nobody else should
```

If the two lists don't match, `NODES` changed after the certificates were made. Re-run `./cb-certs.sh generate` (step 1.2) before going on.

> **Copying new certificates to a node that already has them?** The cluster script never overwrites an existing `~/certs` folder on a node. Delete it first, or the node keeps using the old certificates: `ssh -i "$KEY" "$USER@<node>" 'rm -rf ~/certs'`.

**b) Check you can log in to every node.** Use the SSH key or password your VMs accept. On AWS, this is the `.pem` file of the instance's key pair, and the user is `ec2-user` on Oracle Linux 8.

```bash
KEY=~/path/to/your-key.pem        # the private key for these VMs
USER=ec2-user                     # your SSH user on the VMs
NODES_SSH="cb-data-1.example.internal cb-data-2.example.internal cb-data-3.example.internal cb-index-1.example.internal cb-index-2.example.internal"
                                  # the addresses YOU can reach: DNS names, private IPs, or public IPs

chmod 400 "$KEY"                  # ssh refuses a key that other users can read
for h in $NODES_SSH; do ssh -i "$KEY" "$USER@$h" hostname; done
```

Each node should print its hostname. If you see `Permission denied (publickey,…)`, the key or user is wrong for that VM. On AWS, compare the instance's **Key pair name** in the EC2 console with your `.pem` file. You can ignore any "post-quantum key exchange" warning; it doesn't stop the connection.

> **Using SSH passwords instead of a key?** Leave out `-i "$KEY"` in these commands, and type the password when asked.

**c) Copy the files to every node:**

```bash
for h in $NODES_SSH; do
  echo "== $h"
  scp -i "$KEY" cb-8.0.3-cluster-ol8.sh cb-certs.sh certs.tar.gz "$USER@$h":~/
done
```

**d) Check each node received them:**

```bash
for h in $NODES_SSH; do echo "== $h"; ssh -i "$KEY" "$USER@$h" 'ls -l ~/cb-8.0.3-cluster-ol8.sh ~/cb-certs.sh ~/certs.tar.gz'; done
```

All three files should be listed on every node.

> **Updating a file later** (for example, after changing CONFIG)? Copy it to **every** node again, so all copies of the script match.

### Step 1.5: Run the script on every node

On **each** Couchbase VM, run:

```bash
sudo bash ~/cb-8.0.3-cluster-ol8.sh
```

You can run the nodes in any order, even at the same time, but starting with the bootstrap node (the first line of `NODES`) is simplest. Each node works out its own role from `NODES`:

| Node | What the script does |
|---|---|
| **Bootstrap node** (first in `NODES`) | Checks the OS and AVX2, tunes the kernel, opens `firewalld`, installs Couchbase, creates the cluster, installs its certificate, rebalances in any nodes that have already joined, then creates the buckets and users. It doesn't wait for the other nodes. |
| **Every other node** | Same node setup, then waits (up to `JOIN_TIMEOUT_MIN`) for the bootstrap node. It checks it can reach the bootstrap node on 8091, 18091 and 21100, installs its certificate, adds itself with its services, and **rebalances itself in**. |

Each run takes about 5–10 minutes and ends with `=== Done.` (bootstrap node) or `Run finished` (other nodes).

**Kernel tuning,** applied on every node in step `[2/7]`, following Couchbase's recommendations:

- **Transparent Huge Pages off:** a `disable_thp` service runs before `couchbase-server` at every boot.
- **Swappiness 1:** set in `/etc/sysctl.d/99-couchbase.conf`, plus `vm.force_cgroup_v2_swappiness = 1` on Red Hat kernels.
- **`tuned`:** if it's running, a `couchbase` profile keeps both settings from being overridden.

The log prints the values actually in effect, and a `WARNING:` line if any of them didn't stick. Re-running the script on a node that's already installed applies the current settings.

If a node can't find itself in `NODES` (`does not match any address in NODES`), tell it which entry it is:

```bash
sudo THIS_NODE=cb-data-2.example.internal bash ~/cb-8.0.3-cluster-ol8.sh
```

### Step 1.6: Check the cluster

On any node:

```bash
/opt/couchbase/bin/couchbase-cli server-list -c localhost -u Administrator -p '<strong-password>'
```

Every node should be listed as `healthy active`. Also check:

- **Log:** `/var/log/cb-8.0.3-cluster-install.log` on each node. The bootstrap node's log ends with the list of cluster members.
- **Summary:** `CB_8.0.3_CLUSTER_READY.txt` in the bootstrap node's home folder.
- **Web Console:** `http://<any-node>:8091`, or through an SSH tunnel: `ssh -L 8091:localhost:8091 <user>@<any-node>`, then open `http://localhost:8091`. Under **Servers**, every node should show its services. With `CUSTOM_CERTS="true"`, the "self-signed certificates" warning is gone.

### Step 1.7: Start XDCR from the old cluster

XDCR copies the data across. It's created **on the old cluster**, and the cluster script prints the exact commands for you:

1. In `cb-8.0.3-cluster-ol8.sh`, set `OLD_CLUSTER_HOST` to the old cluster's address, for example `OLD_CLUSTER_HOST="old-cb-1.example.internal"`.
2. Copy the script to the bootstrap node again and re-run it there. This is safe: completed steps are skipped.
   ```bash
   scp cb-8.0.3-cluster-ol8.sh <user>@cb-data-1.example.internal:~/
   ssh <user>@cb-data-1.example.internal 'sudo bash ~/cb-8.0.3-cluster-ol8.sh'
   ```
3. Copy the printed commands and run them **on an old cluster node**: `couchbase-cli xdcr-setup …` once, then one `couchbase-cli xdcr-replicate …` for **each bucket in `BUCKETS`**.

Progress shows on the old cluster's console under **XDCR**. The data has caught up when *changes left* reaches 0.

---

## Part 2: Sync Gateway 4.1 cluster

Every Sync Gateway node is installed **the same way, from the same `migrated/` folder**. Sync Gateway 4.x keeps the database config in the Couchbase bucket. The first node creates the database, and every other node finds it there and skips creating it. A load balancer in front spreads the app traffic.

### Step 2.1: Get the old `sync_gateway.json`

On the old Sync Gateway server, the file is at `/opt/sync_gateway/etc/sync_gateway.json`, owned by root. Copy it to your laptop:

```bash
ssh <user>@old-sgw.example.internal 'sudo cp /opt/sync_gateway/etc/sync_gateway.json ~/ && sudo chown $USER ~/sync_gateway.json'
scp <user>@old-sgw.example.internal:~/sync_gateway.json ./old-sync_gateway.json
```

If it's not at that path, `systemctl cat sync_gateway` on the old server shows which config file the service actually uses. Use the **deployed** file, not a copy taken from a script: `migrate-sgw-config.py` refuses template copies.

### Step 2.2: Convert it to 4.1 files

On your laptop:

```bash
python3 migrate-sgw-config.py --input ./old-sync_gateway.json \
  --new-cb-host cb-data-1.example.internal \
  --new-cb-user sync_gateway --new-cb-password '<sgw-password>' \
  --output-dir ./migrated
```

| Option | Value |
|---|---|
| `--new-cb-host` | **One** new Couchbase node, preferably a data node. Sync Gateway discovers the rest of the cluster from it. |
| `--new-cb-user` / `--new-cb-password` | The user from `USERS` in the cluster script. |
| `--admin-interface` | Optional. Default `127.0.0.1:4985` (Admin API on loopback only). |
| `--public-interface` | Optional. Default `:4984` (public API on all interfaces). |

It writes `migrated/bootstrap.json`, a `migrated/db-config-<db>.json` for each database, and a `migrated/users-<db>.json` where the old config had users.

**Read every warning it prints before going further.** The ones that need a decision:

- **`shared_bucket_access` was not true:** the old Sync Gateway stored metadata inside documents. Test with real data first.
- **`allow_conflicts` / `enable_star_channel` dropped:** 4.x doesn't support them.
- **`use_views`, or a `facebook` / `google` auth block:** flagged, not converted. These need a human decision, and the auth change is visible to app teams.

### Step 2.3: Set the admin login in `sgw-4.1-ol8.sh`

At the top of `sgw-4.1-ol8.sh`, set the **cluster admin** login (the same as `ADMIN_USER` / `ADMIN_PASS` in step 1.1). The script uses it to call Sync Gateway's Admin API:

```bash
CB_ADMIN_USER="Administrator"
CB_ADMIN_PASS="<strong-password>"
```

### Step 2.4: Install on every Sync Gateway node

Copy the script and the `migrated/` folder to each Sync Gateway VM:

```bash
for h in sgw-1.example.internal sgw-2.example.internal; do
  scp -r sgw-4.1-ol8.sh migrated <user>@$h:~/
done
```

Then, on **each** Sync Gateway VM, **one at a time, starting with the first**, run:

```bash
cd ~ && sudo bash sgw-4.1-ol8.sh ./migrated
```

What the script does:

1. reads the Couchbase host from `bootstrap.json`, and checks it can reach it on 8091
2. installs Sync Gateway 4.1.1
3. finds the config path this package actually uses
4. installs `bootstrap.json` there and starts the service cleanly
5. creates each database from `db-config-*.json`, or skips it if it already exists, and waits for it to come online
6. creates or updates the users from `users-*.json`

On the second and later nodes, step 5 reports **`Already exists and online - skipping creation`**, because the database config is already in the bucket. That's expected. If a later node instead stops in step `[6/8]` with an HTTP error saying the database already exists, it hasn't loaded the config from the bucket yet. Wait 30 seconds and run the same command again.

The script **doesn't open the firewall** for Sync Gateway. If `firewalld` is running on the Sync Gateway VMs, open port 4984 on each one:

```bash
sudo firewall-cmd --permanent --add-port=4984/tcp && sudo firewall-cmd --reload
```

- **Log:** `/var/log/sgw-4.1-install.log`
- **Summary:** `SGW_4.1_READY.txt` in your home folder on each node.

> A changed `db-config-*.json` is **not** applied to a database that already exists; the script only creates missing databases. To change one, use the Admin API (`PUT /<db>/_config`), or delete the database and re-run. See [README: Step 6](README.md#step-6-install-sync-gateway-sgw-41-ol8sh).

### Step 2.5: Check each node

On each Sync Gateway VM:

```bash
curl -s http://localhost:4984/                                                # expect "version":"4.1..."
curl -s -u Administrator:'<strong-password>' http://localhost:4985/labdb/      # expect "state":"Online"
curl -s -u Administrator:'<strong-password>' 'http://localhost:4985/labdb/_all_docs?limit=5'
```

Replace `labdb` with your database name: the `<db>` in `migrated/db-config-<db>.json`. The Admin API (4985) listens on localhost only, so run these checks on the node itself.

### Step 2.6: Put the load balancer in front

Point your load balancer at all the Sync Gateway nodes:

| Setting | Value |
|---|---|
| Listener | port **4984** (TCP or HTTP) |
| Members | every Sync Gateway node, port **4984** |
| Health check | HTTP `GET /` on 4984, expect `200` |
| Idle timeout | long, **10 minutes or more**: clients hold `_changes` and WebSocket connections open |
| Session persistence | not needed |

Apps then connect to `http://<load-balancer>:4984`. Never expose port 4985 through it.

### Step 2.7: Test as an app user

Run the tests in [sync_gateway_4984_tests.md](sync_gateway_4984_tests.md) against the load balancer, with these changes:

- **Host:** use the load balancer's address.
- **Version:** expect `4.1` wherever the tests expect `2.1`.
- **Admin API:** it now needs a username and password (`-u`), and it's on loopback only.

The user tests (alice, bob and carol in the lab) only pass once their documents have arrived through XDCR.

---

## Part 3: Migrate the indexes

`migrate-indexes.sh` copies the index **definitions** for one bucket from the old cluster to the new one. No index data is copied: the new cluster builds each index from its own documents.

### Before you run it

| Check | Why |
|---|---|
| The bucket exists on the new cluster | The cluster script created it from `BUCKETS`. |
| XDCR is running (step 1.7) | The indexes are built from the data that's arriving. |
| Port 9102 is reachable on the old cluster's index node **and** on a new index node | The script talks to the Index Service REST API on both. It also uses 8093 on the new node for the final check. |
| The admin login is the same on both clusters | The script uses one `CB_ADMIN_USER` / `CB_ADMIN_PASS` for both. |
| The new cluster has enough index nodes for the old indexes' replicas | An index with 1 replica needs 2 index nodes. |

The simplest place to run it is **a new index node**, because it already has `curl` and `python3`, and reaches its own 9102 and 8093.

### Run it, once per bucket

```bash
scp migrate-indexes.sh <user>@cb-index-1.example.internal:~/
ssh <user>@cb-index-1.example.internal
```

Then, on that node:

```bash
CB_ADMIN_USER=Administrator CB_ADMIN_PASS='<strong-password>' \
  bash ~/migrate-indexes.sh old-cb-index.example.internal cb-index-1.example.internal labdb
```

The arguments are `<old-cluster-host> <new-cluster-host> <bucket>`. Both hosts must run the **index** service. For several buckets, run it once per bucket name.

The script:

1. exports the bucket's index definitions from the old cluster to `/tmp/index-metadata-<bucket>.json`, and prints them
2. restores them on the new cluster: `SUCCESS: index metadata restored`. On a re-run, existing indexes are reported as already existing, which is safe to ignore.
3. lists the new indexes and their state from `system:indexes`

### Check the result

Indexes show `building` until they've indexed the data in the bucket, including data still arriving through XDCR, and then `online`. To see the current state, re-run the query the script ends with:

```bash
/opt/couchbase/bin/cbq -e http://localhost:8093 -u Administrator -p '<strong-password>' \
  -s 'SELECT name, state FROM system:indexes WHERE keyspace_id = "labdb";'
```

You can also watch them in the Web Console under **Indexes**. Compare the list with the old cluster's **Indexes** page.

---

## Final checklist

- [ ] `server-list` shows every Couchbase node `healthy active` (step 1.6)
- [ ] `ca/` is backed up and is only on your laptop (step 1.2)
- [ ] XDCR is running, and *changes left* is going down (step 1.7)
- [ ] Every Sync Gateway node shows version `4.1` and `"state":"Online"` (step 2.5)
- [ ] The load balancer health checks show every Sync Gateway node as up (step 2.6)
- [ ] Every index is `online` on the new cluster (Part 3)

**Cutover** is covered in [README: Step 7](README.md#step-7-verify-then-cut-over): freeze writes on the old side, wait for XDCR *changes left* to reach 0, point the apps at the load balancer, and keep the old environment as the rollback path.

---

## When something fails

Every script stops at the first problem with an `ERROR:` line that says what to fix. Fix it and run the **same command** again.

| Where | Log |
|---|---|
| Couchbase node | `/var/log/cb-8.0.3-cluster-install.log` |
| Sync Gateway node | `/var/log/sgw-4.1-install.log`, and `journalctl -u sync_gateway` |

Common messages from the cluster script:

| Message | Fix |
|---|---|
| `This CPU does not report AVX2 support` | Use a VM or host whose CPU exposes AVX2. On VMware, check the EVC mode. |
| `These NODES names do not resolve on this machine` | Add the DNS records (or `/etc/hosts` entries on every node). |
| `does not match any address in NODES` | Fix the node's `NODES` entry, or run with `THIS_NODE=<its address>`. |
| `Cannot reach bootstrap node … on port(s)` | Open the Couchbase ports between the nodes (see [Before you start](#before-you-start)). |
| `CUSTOM_CERTS is true but … is missing` | Copy `cb-certs.sh` and `certs.tar.gz` (step 1.4) next to the script on that node, or set `CUSTOM_CERTS="false"`. |
| `Bucket RAM adds up to … more than DATA_RAM_MB` | Lower the bucket RAM values or raise `DATA_RAM_MB`. |
| `Bootstrap node … was not initialised within … min` | Get the bootstrap node's run to finish, then re-run this node. |

---

## Changing the cluster later

Make changes through the script and its CONFIG block, so the script stays an accurate record of the cluster:

| To | Do this |
|---|---|
| Add a node | Add its line to `NODES`. With certificates, re-run `./cb-certs.sh generate`, which also rebuilds `certs.tar.gz`. Copy the files to the new node and run the script there; it joins and rebalances itself in. |
| Change memory quotas, bucket RAM, buckets or users | Edit CONFIG and re-run on the bootstrap node. |
| Renew certificates | Re-run `./cb-certs.sh generate`, copy the certificates to the nodes, and re-run the script on each node. |
| Change replicas or storage backend, or remove a node | Not automated. Use the Web Console (or `couchbase-cli`), then rebalance. |

See [README: Changing a running cluster](README.md#changing-a-running-cluster).

## Known gaps

From the README:

- **Sync Gateway → Couchbase traffic isn't encrypted.** `bootstrap.json` uses `couchbase://`, even with `CUSTOM_CERTS="true"`. See [README: Known gaps](README.md#known-gaps) for switching to `couchbases://`.
- **Plain-text passwords:** the scripts and `bootstrap.json` contain them. Restrict who can read the files.
- **XDCR without TLS:** the printed XDCR commands use `--xdcr-secure-connection none`. Decide on TLS before production.
