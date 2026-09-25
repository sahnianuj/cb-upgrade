# Running the Migration Rehearsal Lab on EC2 (Amazon Linux 2)

This installs Couchbase Server 7.0.3 and Sync Gateway 2.1 natively (via their official `.rpm` packages, not Docker) on a single **Amazon Linux 2** EC2 instance. AL2 is used deliberately, not Ubuntu: it's RPM/yum-based and RHEL-lineage, which is the closer match to the Oracle Linux the customer runs in production — and it's on Couchbase Server 7.0.3's own supported-platforms list.

> **Amazon Linux 2, not Amazon Linux 2023.** AL2023 postdates Couchbase Server 7.0.3's certification and isn't on its supported-platforms list; AL2 is. Getting this AMI choice right matters more than it might seem — see the note in Step 2.

**I can't launch this for you** — I have no AWS credentials or network path to EC2 from this chat. Everything below is written for you to run from your own terminal with the AWS CLI configured (`aws sts get-caller-identity` should work), or via the AWS Console.

## What you'll end up with

One `t3.large` instance running:
- Couchbase Server 7.0.3, cluster‑initialized, with a `labdb` bucket, a primary index, and ~8 sample "device/reading" documents
- Sync Gateway 2.1.3, configured against that bucket with a channel‑routing sync function and three sample app users (alice/bob/carol)

All of it is provisioned automatically by `ec2-user-data-al2.sh` at boot — you don't SSH in and run anything by hand unless you want to. Default login user on AL2 is **`ec2-user`**.

## Step 1 — Security group

Create a security group that opens only what's needed, scoped to **your own IP**, not the whole internet:

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)/32
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name cb-sgw-migration-lab \
  --description "Couchbase Server 7.0.3 + Sync Gateway 2.1 migration rehearsal lab" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)

# SSH
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$MY_IP"
# Couchbase Web Console / REST / Query / FTS / Eventing / Analytics
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 8091-8096 --cidr "$MY_IP"
# Couchbase KV (data) service - only needed if you'll connect an SDK from outside the box
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 11210 --cidr "$MY_IP"
# Sync Gateway public REST API
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 4984 --cidr "$MY_IP"
# Sync Gateway ADMIN REST API - keep this one especially tight
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 4985 --cidr "$MY_IP"

echo "Security group: $SG_ID"
```

> Treat port `4985` (Sync Gateway Admin API) and `8091` (Couchbase Console) as sensitive even in a lab — they're wide open on Secure Administration off (2.1's default) with only the credentials in this guide protecting them. Don't widen these CIDRs to `0.0.0.0/0`.

## Step 2 — Launch the instance

Get the current **Amazon Linux 2** AMI ID via AWS's own SSM parameter — this is the authoritative source and avoids the AMI-name-guessing that went wrong with Ubuntu:

```bash
AMI_ID=$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2 \
  --region <your-region> \
  --query 'Parameters[0].Value' --output text)
echo "$AMI_ID"
```

> **Sanity check before launching:** confirm this is actually AL2, not AL2023. The parameter path above is AL2-specific (`amzn2-ami-...`) so it should be correct, but if you ever pull an AMI ID a different way, verify with `aws ec2 describe-images --image-ids $AMI_ID --query 'Images[0].Name'` — the name should contain `amzn2-ami`, not `al2023-ami`.

```bash
aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.large \
  --key-name <your-ec2-key-pair-name> \
  --security-group-ids "$SG_ID" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":50,"VolumeType":"gp3"}}]' \
  --user-data file://ec2-user-data-al2.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=cb-sgw-migration-lab}]' \
  --query 'Instances[0].InstanceId' --output text
```

Note the root device name is `/dev/xvda` for Amazon Linux 2 (not `/dev/sda1`, which is the Ubuntu convention) — if you get a block-device-mapping error, run `aws ec2 describe-images --image-ids "$AMI_ID" --query 'Images[0].RootDeviceName'` to confirm the actual root device name for the AMI you pulled before launching.

Save the returned instance ID. `t3.large` (2 vCPU / 8 GB RAM) is the minimum comfortable size for Couchbase Server + Sync Gateway together on one box for a lab; bump to `t3.xlarge` if you want more headroom for larger sample datasets.

**Prefer the Console instead?** Launch Instances → search "Amazon Linux 2 AMI" and pick the **Amazon Linux 2 AMI (HVM)** entry (not "Amazon Linux 2023 AMI") → `t3.large` → your key pair → the security group from Step 1 → 50 GB gp3 root volume → expand **Advanced details** → paste the entire contents of `ec2-user-data-al2.sh` into **User data** → Launch.

## Step 3 — Wait for provisioning, then check in

Provisioning takes roughly 3–5 minutes (package downloads + cluster init + sample data). Get the public IP:

```bash
INSTANCE_ID=<id-from-step-2>
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "$PUBLIC_IP"
```

SSH in and check progress — **the login user on Amazon Linux 2 is `ec2-user`**, not `ubuntu`:

```bash
ssh -i <your-key.pem> ec2-user@$PUBLIC_IP

# Tail the setup log until you see "=== Done. ==="
tail -f /var/log/user-data.log

# Once it's done:
cat /home/ec2-user/LAB_READY.txt
```

That summary file also records the *exact* RPM filenames the script actually downloaded (the Couchbase Server package name is auto-discovered from the release index rather than hardcoded, since Couchbase's naming for the Amazon-Linux-2-targeted build wasn't fully confirmable from here — worth a quick glance to make sure it grabbed a sensible package).

## Step 4 — Verify from your own machine

```bash
# Couchbase Server is up
curl http://$PUBLIC_IP:8091/pools

# Web Console (Administrator / password123)
open http://$PUBLIC_IP:8091

# Sync Gateway reports version 2.1
curl http://$PUBLIC_IP:4984/
# → {"couchdb":"Welcome","vendor":{"name":"Couchbase Sync Gateway","version":"2.1"},...}

# The labdb database is online
curl http://$PUBLIC_IP:4985/labdb/

# alice can read her own document...
curl -u alice:letmein1 http://$PUBLIC_IP:4984/labdb/device::001
# ...but not bob's (403 - proves channel-based access control is working)
curl -u alice:letmein1 http://$PUBLIC_IP:4984/labdb/device::003
```

## Rehearsing the migration against this instance

This gives you everything Phase 0–4 of the migration runbook assume as the starting environment:

- **Phase 0 (Compatibility):** SSH in and confirm Enterprise Edition (`/opt/couchbase/bin/couchbase-cli server-info` or check the Web Console's license banner), confirm bucket type is Couchbase (it is — `labdb` was created as `--bucket-type couchbase`).
- **Phase 2 (XDCR):** launch a second instance the same way but with a Couchbase Server 8.0.x package URL substituted in a copy of `ec2-user-data-al2.sh` (or reuse the Docker‑based 8.0.2 target from the earlier lab kit), put both instances in the same security group or peer their SGs, and run through the runbook's XDCR setup between them over their private IPs.
- **Phase 3 (Sync Gateway config migration):** this instance uses `shared_bucket_access: true`. To rehearse the higher‑risk `false` scenario from the runbook's Appendix B.5, edit `/home/sync_gateway/sync_gateway.json` on the instance (set `"shared_bucket_access": false`, remove `"enable_shared_bucket_access"` and `"import_docs"`), `systemctl restart sync_gateway`, and re‑seed a few documents — now you have a live example of the inline‑`_sync`‑metadata scenario to migrate.
- **Phase 4 (Cutover):** practice pointing a test client (or just `curl`) at the new environment and back, simulating the freeze/drain/switch sequence.

## Cost note and teardown

`t3.large` runs roughly $0.08/hr in most US regions (check current pricing for yours) plus the 50 GB gp3 volume — inexpensive, but **terminate it when you're done** so it doesn't run indefinitely:

```bash
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
```

If you want to keep the environment around between sessions without paying for a running instance, stop it instead (`aws ec2 stop-instances`) — EBS storage is billed while stopped, but compute isn't.
