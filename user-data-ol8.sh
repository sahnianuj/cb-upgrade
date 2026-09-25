#!/bin/bash
# ============================================================================
# EC2 user-data script (Oracle Linux 8): installs and configures Couchbase
# Server 7.0.3 + Sync Gateway 2.1 - the "old environment" the migration
# runbook assumes as its starting point.
#
# IDEMPOTENT / SAFE TO RE-RUN: every step checks whether its work is already
# done before doing it again. If a previous run got partway through and
# failed, just re-run this same script - it will skip everything already
# completed and pick up from wherever it left off. No separate
# "continuation" script needed.
#
# Target AMI: an OFFICIAL Oracle-published Oracle Linux 8.x AMI (owner ID
# 131827586825 on AWS). Default login user is ec2-user.
#
# Usage as EC2 user-data: paste this whole file into the launch wizard's
# "User data" field, or pass via --user-data-file to `aws ec2 run-instances`.
# Runs once, as root, on first boot via cloud-init.
#
# Usage as a manual re-run: `sudo bash user-data-ol8.sh` on an existing
# instance. Also fine to run repeatedly.
#
# Progress is logged (appended) to /var/log/user-data.log and to the system
# console log (aws ec2 get-console-output --instance-id <id>).
# ============================================================================
set -euo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1
echo "############# Run started: $(date -u '+%Y-%m-%dT%H:%M:%SZ') #############"

CB_VERSION="7.0.3"
SGW_VERSION="2.1.3"
ADMIN_USER="Administrator"
ADMIN_PASS="password123"          # change for anything longer-lived than a lab
SGW_USER="sync_gateway"
SGW_PASS="sgpassword123"
BUCKET_NAME="labdb"
CB_BIN="/opt/couchbase/bin"

echo "=== [0/8] Confirm we're actually on Oracle Linux 8 ==="
if ! grep -qi 'ID="ol"' /etc/os-release || ! grep -q 'PLATFORM_ID="platform:el8"' /etc/os-release; then
  echo "WARNING: /etc/os-release doesn't look like Oracle Linux 8. Contents:"
  cat /etc/os-release
  echo "Continuing anyway, but package downloads below assume RHEL8/OL8 lineage."
fi

echo "=== [1/8] OS prerequisites ==="
# --exclude keeps curl/curl-minimal completely untouched - not reinstalled,
# not upgraded. curl is deliberately not in the install list either: it's
# already present on this AMI, and reinstalling it risks a curl-minimal
# package conflict.
dnf update -y --exclude='curl*'
dnf install -y wget python3 chrony lsof sysstat net-tools

systemctl enable chronyd
systemctl start chronyd

echo "=== [2/8] Production-recommended kernel tuning ==="
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

# Idempotent: only append if not already set, so reruns don't stack up
# duplicate lines in sysctl.conf.
if ! grep -q '^vm.swappiness=0' /etc/sysctl.conf; then
  echo 'vm.swappiness=0' >> /etc/sysctl.conf
fi
sysctl -p

echo "=== [3/8] Installing Couchbase Server ${CB_VERSION} ==="
if rpm -q couchbase-server > /dev/null 2>&1; then
  echo "Couchbase Server already installed ($(rpm -q couchbase-server)), skipping download/install."
else
  cd /tmp
  CB_BASE_URL="https://packages.couchbase.com/releases/${CB_VERSION}"

  # packages.couchbase.com is CloudFront in front of an S3 bucket with
  # ListBucket disabled - the bare directory URL always 403s, even though
  # individual files are directly downloadable by exact filename. So: don't
  # try to list/scrape it. Try known filename patterns directly instead,
  # newest naming convention first.
  CB_CANDIDATES=(
    "couchbase-server-enterprise-${CB_VERSION}-linux.x86_64.rpm"
    "couchbase-server-enterprise-${CB_VERSION}-centos8.x86_64.rpm"
    "couchbase-server-enterprise-${CB_VERSION}-rhel8.x86_64.rpm"
    "couchbase-server-enterprise-${CB_VERSION}-oel8.x86_64.rpm"
    "couchbase-server-enterprise-${CB_VERSION}-centos7.x86_64.rpm"
  )

  CB_RPM=""
  for candidate in "${CB_CANDIDATES[@]}"; do
    echo "Trying: ${CB_BASE_URL}/${candidate}"
    if curl -sS --fail --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 120 \
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
    echo "Check https://www.couchbase.com/downloads (Couchbase Server, version ${CB_VERSION}, Linux) for the exact current filename and adjust CB_CANDIDATES in this script." >&2
    exit 1
  fi
  dnf install -y "./${CB_RPM}"
fi

echo "=== [4/8] Waiting for Couchbase Server to accept connections ==="
CB_READY=0
for i in $(seq 1 60); do
  status=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 http://localhost:8091/pools 2>/dev/null || echo "000")
  # 200 = pre-init, open. 401 = server is fully up and answering correctly,
  # it's just that a cluster was already initialized (e.g. by an earlier
  # run of this idempotent script) and this endpoint now requires auth.
  # Both mean "the REST API is live" - only treat 000/5xx/etc as not-ready.
  if [ "${status}" = "200" ] || [ "${status}" = "401" ]; then
    CB_READY=1
    break
  fi
  case "${status}" in
    000) reason="no HTTP response - connection refused, timed out, or DNS/socket issue" ;;
    *)   reason="unexpected HTTP status" ;;
  esac
  echo "  [${i}/60] Not ready yet: HTTP ${status} (${reason}) - waiting 5s..."
  # Every 4th attempt, dump a verbose probe so you can see *why* if this
  # keeps failing, instead of just watching bare status codes scroll by.
  if [ $(( i % 4 )) -eq 0 ]; then
    echo "  --- verbose probe at attempt ${i} ---"
    curl -v --connect-timeout 5 --max-time 10 http://localhost:8091/pools 2>&1 | sed 's/^/    /' || true
    echo "  --- end verbose probe ---"
  fi
  sleep 5
done
if [ "${CB_READY}" -ne 1 ]; then
  echo "ERROR: Couchbase Server did not become ready within 5 minutes." >&2
  echo "--- final verbose curl attempt ---" >&2
  curl -v --connect-timeout 5 --max-time 10 http://localhost:8091/pools 2>&1 >&2 || true
  echo "--- systemctl status ---" >&2
  systemctl status couchbase-server --no-pager >&2 || true
  echo "--- is anything listening on 8091? ---" >&2
  ss -tlnp 2>/dev/null | grep 8091 >&2 || echo "  (nothing listening on 8091)" >&2
  echo "--- last 50 lines of babysitter.log ---" >&2
  tail -n 50 /opt/couchbase/var/lib/couchbase/logs/babysitter.log >&2 || true
  exit 1
fi
echo "Couchbase Server is ready (HTTP ${status})."

echo "=== [5/8] Provisioning cluster, bucket, RBAC user, and sample data ==="

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
    --cluster-name "migration-lab-ec2-ol8"
fi

echo "-- Bucket create --"
if "${CB_BIN}/couchbase-cli" bucket-list -c "localhost:8091" -u "${ADMIN_USER}" -p "${ADMIN_PASS}" | grep -x "${BUCKET_NAME}" > /dev/null; then
  echo "Bucket ${BUCKET_NAME} already exists, skipping."
else
  "${CB_BIN}/couchbase-cli" bucket-create -c "localhost:8091" \
    -u "${ADMIN_USER}" -p "${ADMIN_PASS}" \
    --bucket "${BUCKET_NAME}" \
    --bucket-type couchbase \
    --bucket-ramsize 1024 \
    --enable-flush 1 \
    --wait
fi

echo "-- RBAC user for Sync Gateway --"
# --set is inherently idempotent: creates the user if absent, overwrites if present.
"${CB_BIN}/couchbase-cli" user-manage -c "localhost:8091" \
  -u "${ADMIN_USER}" -p "${ADMIN_PASS}" \
  --set --rbac-username "${SGW_USER}" --rbac-password "${SGW_PASS}" \
  --roles "bucket_full_access[${BUCKET_NAME}]" \
  --rbac-name "Sync Gateway lab user" \
  --auth-domain local

echo "-- Primary index --"
# CREATE PRIMARY INDEX ... IF NOT EXISTS has failed with a syntax error in
# two different clause placements on this Couchbase Server version - rather
# than keep guessing N1QL DDL grammar, drop IF NOT EXISTS entirely and
# handle idempotency by inspecting the response instead: treat "success" or
# an "already exists" error as fine, anything else as a real failure.
idx_out=$("${CB_BIN}/cbq" -engine="http://localhost:8093" -u "${ADMIN_USER}" -p "${ADMIN_PASS}" -script="CREATE PRIMARY INDEX ON \`${BUCKET_NAME}\`;" 2>&1)
if grep -qi '"status": "success"' <<< "${idx_out}"; then
  echo "Primary index created."
elif grep -qi 'already exists' <<< "${idx_out}"; then
  echo "Primary index already exists, skipping."
else
  echo "ERROR: primary index creation failed:" >&2
  echo "${idx_out}" >&2
  exit 1
fi

echo "-- Sample data (UPSERT, safe to re-run) --"
# cbq's -script flag accepts exactly ONE N1QL statement per invocation, not
# a semicolon-separated batch (that produces "syntax error - at UPSERT" on
# the second statement) - so call it once per document instead.
SAMPLE_DOCS=(
  "UPSERT INTO \`${BUCKET_NAME}\` (KEY, VALUE) VALUES ('device::001', {'type':'device','deviceId':'001','owner':'alice','model':'sensor-A','status':'active','lastSeen':'2026-09-01T10:00:00Z'});"
  "UPSERT INTO \`${BUCKET_NAME}\` (KEY, VALUE) VALUES ('device::002', {'type':'device','deviceId':'002','owner':'alice','model':'sensor-B','status':'active','lastSeen':'2026-09-02T09:30:00Z'});"
  "UPSERT INTO \`${BUCKET_NAME}\` (KEY, VALUE) VALUES ('device::003', {'type':'device','deviceId':'003','owner':'bob','model':'sensor-A','status':'inactive','lastSeen':'2026-08-20T14:12:00Z'});"
  "UPSERT INTO \`${BUCKET_NAME}\` (KEY, VALUE) VALUES ('device::004', {'type':'device','deviceId':'004','owner':'bob','model':'sensor-C','status':'active','lastSeen':'2026-09-05T08:00:00Z'});"
  "UPSERT INTO \`${BUCKET_NAME}\` (KEY, VALUE) VALUES ('device::005', {'type':'device','deviceId':'005','owner':'carol','model':'sensor-B','status':'active','lastSeen':'2026-09-06T11:45:00Z'});"
  "UPSERT INTO \`${BUCKET_NAME}\` (KEY, VALUE) VALUES ('reading::001-01', {'type':'reading','deviceId':'001','owner':'alice','value':21.4,'unit':'C','recordedAt':'2026-09-01T10:05:00Z'});"
  "UPSERT INTO \`${BUCKET_NAME}\` (KEY, VALUE) VALUES ('reading::001-02', {'type':'reading','deviceId':'001','owner':'alice','value':21.9,'unit':'C','recordedAt':'2026-09-01T11:05:00Z'});"
  "UPSERT INTO \`${BUCKET_NAME}\` (KEY, VALUE) VALUES ('reading::004-01', {'type':'reading','deviceId':'004','owner':'bob','value':45.2,'unit':'percent','recordedAt':'2026-09-05T08:10:00Z'});"
)
doc_count=0
for stmt in "${SAMPLE_DOCS[@]}"; do
  cbq_out=$("${CB_BIN}/cbq" -engine="http://localhost:8093" -u "${ADMIN_USER}" -p "${ADMIN_PASS}" -script="${stmt}" 2>&1)
  if grep -q '"status": "success"' <<< "${cbq_out}"; then
    doc_count=$((doc_count + 1))
  else
    echo "ERROR: sample data statement failed:" >&2
    echo "  ${stmt}" >&2
    echo "${cbq_out}" >&2
    exit 1
  fi
done
echo "Sample data loaded (${doc_count}/${#SAMPLE_DOCS[@]} documents)."

echo "=== [6/8] Installing Sync Gateway ${SGW_VERSION} ==="
if rpm -q couchbase-sync-gateway > /dev/null 2>&1; then
  echo "Sync Gateway already installed ($(rpm -q couchbase-sync-gateway)), skipping download/install."
else
  cd /tmp
  SGW_BASE_URL="https://packages.couchbase.com/releases/couchbase-sync-gateway/${SGW_VERSION}"

  SGW_CANDIDATES=(
    "couchbase-sync-gateway-enterprise_${SGW_VERSION}_x86_64.rpm"
    "couchbase-sync-gateway-enterprise-${SGW_VERSION}_x86_64.rpm"
    "couchbase-sync-gateway-enterprise_${SGW_VERSION}-x86_64.rpm"
  )

  SGW_RPM=""
  for candidate in "${SGW_CANDIDATES[@]}"; do
    echo "Trying: ${SGW_BASE_URL}/${candidate}"
    if curl -sS --fail --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 60 \
         -o "${candidate}" "${SGW_BASE_URL}/${candidate}"; then
      SGW_RPM="${candidate}"
      echo "Found working package: ${SGW_RPM}"
      break
    fi
    rm -f "${candidate}"
  done

  if [ -z "${SGW_RPM}" ]; then
    echo "ERROR: none of the following candidate filenames were downloadable from ${SGW_BASE_URL}/:" >&2
    printf '  %s\n' "${SGW_CANDIDATES[@]}" >&2
    echo "Check https://www.couchbase.com/downloads (Sync Gateway, version ${SGW_VERSION}) for the exact current filename and adjust SGW_CANDIDATES in this script." >&2
    exit 1
  fi
  dnf install -y "./${SGW_RPM}"
fi

echo "=== [7/8] Writing Sync Gateway configuration ==="
# Clean up the stale /etc/sysconfig/sync_gateway override from an earlier,
# incorrect assumption about how this init script resolves its config path -
# it's not sourced anywhere in the actual script, so leaving it around is
# just misleading.
rm -f /etc/sysconfig/sync_gateway
# The Sync Gateway RPM on this system ships an old-style SysV init script
# (/etc/rc.d/init.d/sync_gateway) with a HARDCODED config path -
# /opt/sync_gateway/etc/sync_gateway.json - and no /etc/sysconfig override
# support at all (confirmed by reading the actual init script; an earlier
# assumption that it supported a sysconfig override was wrong). Write the
# config to the path the init script actually uses, not the general
# Sync Gateway documentation default.
SGW_CONFIG_DIR="/opt/sync_gateway/etc"
SGW_CONFIG_PATH="${SGW_CONFIG_DIR}/sync_gateway.json"
install -d -m 0755 -o sync_gateway -g sync_gateway "${SGW_CONFIG_DIR}"
cat > "${SGW_CONFIG_PATH}" << EOF
{
  "interface": ":4984",
  "adminInterface": ":4985",
  "logging": {
    "console": {
      "log_level": "info",
      "log_keys": ["HTTP", "CRUD", "Cache", "Changes"]
    }
  },
  "databases": {
    "${BUCKET_NAME}": {
      "server": "http://localhost:8091",
      "bucket": "${BUCKET_NAME}",
      "username": "${SGW_USER}",
      "password": "${SGW_PASS}",
      "num_index_replicas": 0,
      "shared_bucket_access": true,
      "import_docs": true,
      "enable_shared_bucket_access": true,
      "revs_limit": 20,
      "allow_conflicts": true,
      "sync": \`
        function(doc, oldDoc) {
          if (doc.owner) {
            channel(doc.owner);
            access(doc.owner, doc.owner);
          }
          if (doc._deleted) {
            return;
          }
        }
      \`,
      "users": {
        "GUEST": { "disabled": true },
        "alice": { "password": "letmein1", "admin_channels": ["alice"] },
        "bob":   { "password": "letmein2", "admin_channels": ["bob"] },
        "carol": { "password": "letmein3", "admin_channels": ["carol"] }
      }
    }
  }
}
EOF
chown sync_gateway:sync_gateway "${SGW_CONFIG_PATH}"

echo "=== [8/8] Starting Sync Gateway ==="
systemctl enable sync_gateway

# The RPM's own post-install step can auto-start sync_gateway (with
# whatever default/example config existed on disk at install time) BEFORE
# our real config exists. Because that process was started outside of
# systemd's own tracking, `systemctl restart` can become a no-op from
# systemd's point of view - it thinks the unit isn't active, so "restart"
# degrades to "start" only, and the init script's own is_running() check
# then correctly finds the untracked process already holding the PID file
# and refuses to start a second one ("Already started" in the log), so our
# new config never actually loads. Force a real stop first, don't trust
# `restart` alone to get there.
echo "-- Stopping any existing Sync Gateway process (including any started by RPM post-install) --"
systemctl stop sync_gateway 2>/dev/null || true
# Belt-and-suspenders: kill by exact binary path in case a process is
# running outside anything the PID file is tracking at all.
pkill -f '/opt/couchbase-sync-gateway/bin/sync_gateway' 2>/dev/null || true
sleep 2
rm -f /var/run/sync-gateway.pid

echo "-- Starting Sync Gateway with the correct config --"
systemctl start sync_gateway

# Verify with a short retry loop rather than one fixed sleep - startup time
# can vary a little.
SGW_READY=0
for i in $(seq 1 12); do
  if curl -sf http://localhost:4984/ > /dev/null 2>&1; then
    SGW_READY=1
    break
  fi
  sleep 5
done
if [ "${SGW_READY}" -eq 1 ]; then
  echo "Sync Gateway is responding on :4984."
else
  echo "WARNING: Sync Gateway did not respond on :4984 after 60s - check 'journalctl -u sync_gateway' and /var/log/sync_gateway/"
fi

# Server responding is not the same as the database actually loading - and
# checking the public API (4984) is ambiguous here, since GUEST is disabled
# in our config and a correctly-enforced 401 "Login required" looks like
# failure to a bare `curl -sf` even though it actually proves the database
# IS online (a genuinely missing database returns 404 "not_found" instead).
# The Admin API (4985) has no auth requirement on Sync Gateway 2.1, so check
# there instead for an unambiguous answer. Retry a few times - database
# load (bucket connection, index verification) can lag a bit behind the
# port itself accepting connections.
DB_ONLINE=0
for i in $(seq 1 6); do
  if curl -s http://localhost:4985/_all_dbs 2>/dev/null | grep "\"${BUCKET_NAME}\"" > /dev/null; then
    DB_ONLINE=1
    break
  fi
  sleep 5
done
if [ "${DB_ONLINE}" -eq 1 ]; then
  echo "Database '${BUCKET_NAME}' is online."
else
  echo "WARNING: database '${BUCKET_NAME}' did not come online after 30s. Diagnostics:" >&2
  echo "-- _all_dbs contents --" >&2
  curl -s http://localhost:4985/_all_dbs >&2 || true
  echo >&2
  echo "--- what config path is the running process actually using? ---" >&2
  ps -ef | grep sync_gateway | grep -v grep >&2 || true
  echo "--- recent sync_gateway log activity ---" >&2
  journalctl -u sync_gateway -n 40 --no-pager >&2 || true
  echo "--- sync_gateway's own error log ---" >&2
  tail -n 40 /var/log/sync_gateway/sync_gateway_error.log >&2 2>&1 || true
fi

# --- Write a summary file for whoever SSHes in ---
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "<unavailable>")

cat > /home/ec2-user/LAB_READY.txt << EOF
Couchbase Server ${CB_VERSION} + Sync Gateway ${SGW_VERSION} lab is provisioned (Oracle Linux 8).

Couchbase Web Console:  http://${PUBLIC_IP}:8091   (${ADMIN_USER} / ${ADMIN_PASS})
Sync Gateway public API: http://${PUBLIC_IP}:4984
Sync Gateway admin API:  http://${PUBLIC_IP}:4985
Bucket / SGW database:   ${BUCKET_NAME}
Sync Gateway RBAC user:  ${SGW_USER} / ${SGW_PASS}
Sample app users:        alice/letmein1, bob/letmein2, carol/letmein3

Quick checks:
  curl http://localhost:4984/
  curl http://localhost:4985/${BUCKET_NAME}/
  curl -u alice:letmein1 http://localhost:4984/${BUCKET_NAME}/device::001

This script is safe to re-run (idempotent) - see /var/log/user-data.log for
the full history if you've run it more than once.
EOF
chown ec2-user:ec2-user /home/ec2-user/LAB_READY.txt

echo "############# Run finished: $(date -u '+%Y-%m-%dT%H:%M:%SZ') #############"
echo "=== Done. See /home/ec2-user/LAB_READY.txt for connection details. ==="
