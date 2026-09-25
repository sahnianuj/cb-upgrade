#!/bin/bash
# ============================================================================
# Standalone Couchbase Server 8.0.3 install + provisioning, on its OWN
# machine (separate from Sync Gateway). Oracle Linux 8 target.
#
# This is the "new environment" side of the parallel-cluster + XDCR
# migration - it does NOT touch the old 7.0.3 cluster. Once this cluster is
# up, wire up XDCR from the OLD cluster to this one manually (or fill in
# OLD_CLUSTER_HOST below to have this script attempt it automatically), then
# run migrate-indexes.sh to bring index definitions across, then run the
# Sync Gateway 4.1.x script on a SEPARATE machine pointed at this cluster.
#
# IDEMPOTENT / SAFE TO RE-RUN: same pattern as the 7.0.3 script - every step
# checks its own state before acting.
#
# Usage: sudo bash cb-8.0.3-ol8.sh   (as EC2 user-data, or manually)
# ============================================================================
set -euo pipefail
exec > >(tee -a /var/log/cb-8.0.3-install.log) 2>&1
echo "############# Run started: $(date -u '+%Y-%m-%dT%H:%M:%SZ') #############"

CB_VERSION="8.0.3"
ADMIN_USER="Administrator"
ADMIN_PASS="password123"
SGW_USER="sync_gateway"
SGW_PASS="sgpassword123"
BUCKET_NAME="labdb"
CB_BIN="/opt/couchbase/bin"

# Fill this in with the OLD (7.0.3) cluster's hostname/IP to have this
# script also set up the XDCR remote-cluster reference + replication
# automatically. Leave blank to set XDCR up manually/later.
OLD_CLUSTER_HOST=""

echo "=== [0/7] Confirm OS and AVX2 CPU support (hard requirement for CBS 8.0+) ==="
if ! grep -qi 'ID="ol"' /etc/os-release || ! grep -q 'PLATFORM_ID="platform:el8"' /etc/os-release; then
  echo "WARNING: /etc/os-release doesn't look like Oracle Linux 8. Contents:"
  cat /etc/os-release
fi
if ! grep -q avx2 /proc/cpuinfo; then
  echo "ERROR: this CPU does not report AVX2 support. Couchbase Server 8.0+ will refuse to start on this instance type." >&2
  echo "Pick an instance type with a newer CPU generation (most current-generation EC2 types qualify)." >&2
  exit 1
fi
echo "AVX2 confirmed present."

echo "=== [1/7] OS prerequisites ==="
dnf update -y --exclude='curl*'
dnf install -y wget python3 chrony lsof sysstat net-tools
systemctl enable chronyd
systemctl start chronyd

echo "=== [2/7] Production-recommended kernel tuning ==="
if [ ! -f /etc/systemd/system/disable_thp.service ]; then
  cat > /etc/systemd/system/disable_thp.service << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)

[Service]
Type=simple
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag"

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
fi
systemctl enable --now disable_thp

if ! grep -q '^vm.swappiness=0' /etc/sysctl.conf; then
  echo 'vm.swappiness=0' >> /etc/sysctl.conf
fi
sysctl -p

echo "=== [3/7] Installing Couchbase Server ${CB_VERSION} ==="
if rpm -q couchbase-server > /dev/null 2>&1; then
  echo "Couchbase Server already installed ($(rpm -q couchbase-server)), skipping download/install."
else
  cd /tmp
  CB_BASE_URL="https://packages.couchbase.com/releases/${CB_VERSION}"

  # packages.couchbase.com is CloudFront/S3 with ListBucket disabled - the
  # directory URL always 403s, so try known exact filenames directly.
  # By 8.x, Couchbase's evidence points to a single unified "-linux" build
  # rather than per-distro tags, so try that first.
  CB_CANDIDATES=(
    "couchbase-server-enterprise-${CB_VERSION}-linux.x86_64.rpm"
    "couchbase-server-enterprise-${CB_VERSION}-centos8.x86_64.rpm"
    "couchbase-server-enterprise-${CB_VERSION}-rhel8.x86_64.rpm"
    "couchbase-server-enterprise-${CB_VERSION}-oel8.x86_64.rpm"
  )

  CB_RPM=""
  for candidate in "${CB_CANDIDATES[@]}"; do
    echo "Trying: ${CB_BASE_URL}/${candidate}"
    if curl -sS --fail --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 180 \
         -o "${candidate}" "${CB_BASE_URL}/${candidate}"; then
      CB_RPM="${candidate}"
      echo "Found working package: ${CB_RPM}"
      break
    fi
    rm -f "${candidate}"
  done

  if [ -z "${CB_RPM}" ]; then
    echo "ERROR: none of the following candidate filenames were downloadable from ${CB_BASE_URL}/:" >&2
    printf '  %s\n' "${CB_CANDIDATES[@]}" >&2
    echo "Check https://www.couchbase.com/downloads (Couchbase Server, version ${CB_VERSION}, Linux) for the exact current filename and adjust CB_CANDIDATES." >&2
    exit 1
  fi
  dnf install -y "./${CB_RPM}"
fi

echo "=== [4/7] Waiting for Couchbase Server to accept connections ==="
CB_READY=0
for i in $(seq 1 60); do
  # curl's -w '%{http_code}' already prints "000" itself on a connection
  # failure (documented curl behavior) - the old `|| echo "000"` fallback
  # here was redundant and, worse, fired IN ADDITION on curl's non-zero
  # exit, producing a doubled "000000" in the log. Removed.
  status=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 http://localhost:8091/pools 2>/dev/null)
  # 200 = pre-init/open. 401 = fully up, cluster already initialized and
  # this endpoint now requires auth. Both prove the REST API is live.
  if [ "${status}" = "200" ] || [ "${status}" = "401" ]; then
    CB_READY=1
    break
  fi
  echo "  [${i}/60] Not ready yet: HTTP ${status} - waiting 5s..."
  if [ $(( i % 4 )) -eq 0 ]; then
    echo "  --- verbose probe at attempt ${i} ---"
    curl -v --connect-timeout 5 --max-time 10 http://localhost:8091/pools 2>&1 | sed 's/^/    /' || true
    echo "  --- end verbose probe ---"
  fi
  sleep 5
done
if [ "${CB_READY}" -ne 1 ]; then
  echo "ERROR: Couchbase Server did not become ready within 5 minutes." >&2
  systemctl status couchbase-server --no-pager >&2 || true
  ss -tlnp 2>/dev/null | grep 8091 >&2 || echo "  (nothing listening on 8091)" >&2
  tail -n 50 /opt/couchbase/var/lib/couchbase/logs/babysitter.log >&2 || true
  exit 1
fi
echo "Couchbase Server is ready."

echo "=== [5/7] Provisioning cluster, bucket (1024 vBuckets for XDCR compatibility), RBAC user ==="

echo "-- Cluster init --"
if curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" "http://localhost:8091/pools/default" | grep '"clusterName"' > /dev/null; then
  echo "Cluster already initialized, skipping cluster-init."
else
  "${CB_BIN}/couchbase-cli" cluster-init \
    -c "localhost:8091" \
    --cluster-username "${ADMIN_USER}" \
    --cluster-password "${ADMIN_PASS}" \
    --cluster-ramsize 2048 \
    --cluster-index-ramsize 512 \
    --services data,index,query \
    --cluster-name "migration-lab-8.0.3"
fi

echo "-- Bucket create (Couchstore backend - always 1024 vBuckets by default, no flag needed - required to receive XDCR from the pre-8.0 source cluster) --"
if "${CB_BIN}/couchbase-cli" bucket-list -c "localhost:8091" -u "${ADMIN_USER}" -p "${ADMIN_PASS}" | grep -x "${BUCKET_NAME}" > /dev/null; then
  echo "Bucket ${BUCKET_NAME} already exists, skipping."
else
  # --num-vbuckets is only accepted on Magma buckets (it overrides Magma's
  # normal 128-vBucket default down to 1024 for pre-8.0 XDCR compatibility).
  # Couchstore is ALWAYS 1024 vBuckets already, so no flag is needed at all
  # here - passing --num-vbuckets on a Couchstore bucket is rejected
  # ("only valid for Magma buckets").
  "${CB_BIN}/couchbase-cli" bucket-create -c "localhost:8091" \
    -u "${ADMIN_USER}" -p "${ADMIN_PASS}" \
    --bucket "${BUCKET_NAME}" \
    --bucket-type couchbase \
    --storage-backend couchstore \
    --bucket-ramsize 1024 \
    --enable-flush 1 \
    --wait
fi

echo "-- RBAC user for Sync Gateway --"
"${CB_BIN}/couchbase-cli" user-manage -c "localhost:8091" \
  -u "${ADMIN_USER}" -p "${ADMIN_PASS}" \
  --set --rbac-username "${SGW_USER}" --rbac-password "${SGW_PASS}" \
  --roles "bucket_full_access[${BUCKET_NAME}]" \
  --rbac-name "Sync Gateway lab user" \
  --auth-domain local

echo "=== [6/7] Optional: XDCR from the old cluster ==="
if [ -n "${OLD_CLUSTER_HOST}" ]; then
  echo "OLD_CLUSTER_HOST is set (${OLD_CLUSTER_HOST}) - note this must be run FROM the old cluster's side"
  echo "(XDCR replications are created on the SOURCE cluster, pointing AT the target)."
  echo "This script only prepared the target; run the following on the OLD (7.0.3) cluster:"
  echo ""
  echo "  couchbase-cli xdcr-setup -c ${OLD_CLUSTER_HOST}:8091 -u ${ADMIN_USER} -p ${ADMIN_PASS} \\"
  echo "    --create --xdcr-cluster-name new-8.0-cluster \\"
  echo "    --xdcr-hostname <this-machine's-hostname-or-IP> \\"
  echo "    --xdcr-username ${ADMIN_USER} --xdcr-password ${ADMIN_PASS} \\"
  echo "    --xdcr-secure-connection none"
  echo ""
  echo "  couchbase-cli xdcr-replicate -c ${OLD_CLUSTER_HOST}:8091 -u ${ADMIN_USER} -p ${ADMIN_PASS} \\"
  echo "    --create --xdcr-cluster-name new-8.0-cluster \\"
  echo "    --xdcr-from-bucket ${BUCKET_NAME} --xdcr-to-bucket ${BUCKET_NAME} \\"
  echo "    --xdcr-replication-mode xmem"
else
  echo "OLD_CLUSTER_HOST not set - skipping. Set up XDCR manually from the old cluster when ready"
  echo "(see the migration runbook, Phase 2.4), or fill in OLD_CLUSTER_HOST and re-run this script"
  echo "for the exact commands to run on the old side."
fi

echo "=== [7/7] Summary ==="
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "<unavailable>")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || echo "<unavailable>")

cat > /home/ec2-user/CB_8.0.3_READY.txt << EOF
Couchbase Server ${CB_VERSION} is provisioned on this machine (Oracle Linux 8).

Web Console:   http://${PUBLIC_IP}:8091   (${ADMIN_USER} / ${ADMIN_PASS})
Bucket:        ${BUCKET_NAME}  (1024 vBuckets - ready to receive XDCR from a pre-8.0 source)
SGW RBAC user: ${SGW_USER} / ${SGW_PASS}
Private IP (use this for XDCR / Sync Gateway bootstrap on other machines): ${PRIVATE_IP}

Next steps:
  1. Set up XDCR from the old cluster - see step [6/7] output above, or the runbook.
  2. Run migrate-indexes.sh once data has started flowing, to bring index definitions across.
  3. On a SEPARATE machine, run sgw-4.1-ol8.sh, pointing it at this machine's private IP.

This script is safe to re-run. See /var/log/cb-8.0.3-install.log for full history.
EOF
chown ec2-user:ec2-user /home/ec2-user/CB_8.0.3_READY.txt

echo "############# Run finished: $(date -u '+%Y-%m-%dT%H:%M:%SZ') #############"
echo "=== Done. See /home/ec2-user/CB_8.0.3_READY.txt for details. ==="
