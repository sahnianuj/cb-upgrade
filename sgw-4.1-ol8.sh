#!/bin/bash
# ============================================================================
# Standalone Sync Gateway 4.1.x install + provisioning, on its OWN machine,
# consuming a pre-generated "migrated" folder (from migrate-sgw-config.py)
# as the SINGLE SOURCE OF TRUTH for configuration - no hardcoded db/user
# values in this script.
#
# Expects, in MIGRATED_DIR:
#   bootstrap.json            - node-level connection config
#   db-config-<dbname>.json   - one or more, database config payloads
#   users-<dbname>.json       - optional, matching per-database user configs
#
# If you haven't generated these yet, run migrate-sgw-config.py first.
#
# IDEMPOTENT / SAFE TO RE-RUN: every step checks its own state before
# acting, same discipline as cb-8.0.3-ol8.sh and user-data-ol8.sh.
#
# Usage:
#   sudo bash sgw-4.1-ol8.sh [path-to-migrated-folder]
#   (defaults to ./migrated if not given)
# ============================================================================
set -euo pipefail
exec > >(tee -a /var/log/sgw-4.1-install.log) 2>&1
echo "############# Run started: $(date -u '+%Y-%m-%dT%H:%M:%SZ') #############"

MIGRATED_DIR="${1:-./migrated}"
SGW_VERSION="4.1.1"
CB_ADMIN_USER="Administrator"
CB_ADMIN_PASS="password123"
SGW_ADMIN_URL="http://localhost:4985"

echo "=== [0/8] Locating migrated config files in ${MIGRATED_DIR} ==="
if [ ! -f "${MIGRATED_DIR}/bootstrap.json" ]; then
  echo "ERROR: ${MIGRATED_DIR}/bootstrap.json not found." >&2
  echo "Generate it first with migrate-sgw-config.py, e.g.:" >&2
  echo "  python3 migrate-sgw-config.py --input ./old-sync_gateway.json \\" >&2
  echo "    --new-cb-host <new-cluster-private-ip> \\" >&2
  echo "    --new-cb-user sync_gateway --new-cb-password sgpassword123 \\" >&2
  echo "    --output-dir ${MIGRATED_DIR}" >&2
  exit 1
fi

# Absolute path BEFORE listing the files: the install step cd's to /tmp, and
# relative paths in DB_CONFIG_FILES would then point at the wrong place.
MIGRATED_DIR="$(cd "${MIGRATED_DIR}" && pwd)"
DB_CONFIG_FILES=("${MIGRATED_DIR}"/db-config-*.json)
if [ ! -e "${DB_CONFIG_FILES[0]}" ]; then
  echo "ERROR: no db-config-*.json files found in ${MIGRATED_DIR}." >&2
  exit 1
fi
echo "Found bootstrap.json and ${#DB_CONFIG_FILES[@]} database config(s):"
printf '  %s\n' "${DB_CONFIG_FILES[@]}"


# Pull the Couchbase Server host out of bootstrap.json itself - this file
# is the single source of truth for connection details, no separate
# hardcoded CB_HOST variable to keep in sync with it.
CB_HOST=$(python3 -c "
import json
with open('${MIGRATED_DIR}/bootstrap.json') as f:
    data = json.load(f)
server = data['bootstrap']['server']
print(server.split('://', 1)[1] if '://' in server else server)
")
if [ -z "${CB_HOST}" ]; then
  echo "ERROR: could not extract a server host from ${MIGRATED_DIR}/bootstrap.json's bootstrap.server field." >&2
  exit 1
fi
echo "Couchbase Server host (from bootstrap.json): ${CB_HOST}"

echo "=== [1/8] Confirm OS and target cluster reachability ==="
if ! grep -qi 'ID="ol"' /etc/os-release || ! grep -q 'PLATFORM_ID="platform:el8"' /etc/os-release; then
  echo "WARNING: /etc/os-release doesn't look like Oracle Linux 8:"
  cat /etc/os-release
fi
if ! curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "http://${CB_HOST}:8091/pools" 2>/dev/null | grep -E '^(200|401)$' > /dev/null; then
  echo "ERROR: cannot reach Couchbase Server at ${CB_HOST}:8091. Confirm the host, that CBS is running, and security groups allow this machine to reach it (8091, and 11210 for the actual data connection)." >&2
  exit 1
fi
echo "Couchbase Server at ${CB_HOST} is reachable."

echo "=== [2/8] OS prerequisites ==="
dnf update -y --exclude='curl*'
dnf install -y wget python3 chrony
systemctl enable chronyd
systemctl start chronyd

echo "=== [3/8] Installing Sync Gateway ${SGW_VERSION} ==="
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
    exit 1
  fi
  dnf install -y "./${SGW_RPM}"
fi

echo "=== [4/8] Locating this install's actual config path ==="
# Same lesson as the 2.1 install: don't trust the documented default - find
# the real path this specific packaging uses.
if systemctl cat sync_gateway 2>/dev/null | grep "Automatically generated by systemd-sysv-generator" > /dev/null; then
  echo "Generated SysV-compat shim detected (same situation as the 2.1 install)."
  SGW_INIT_SCRIPT=$(systemctl cat sync_gateway 2>/dev/null | grep -oE '/etc/rc\.d/init\.d/[a-zA-Z_-]+' | head -n1)
  SGW_CONFIG_PATH=""
  if [ -n "${SGW_INIT_SCRIPT}" ] && [ -f "${SGW_INIT_SCRIPT}" ]; then
    echo "Init script: ${SGW_INIT_SCRIPT}"
    grep -i '^CONFIG=' "${SGW_INIT_SCRIPT}" || echo "  (no CONFIG= line found)"
    SGW_CONFIG_PATH=$(grep -oE '^CONFIG=\S+' "${SGW_INIT_SCRIPT}" | cut -d= -f2)
  fi
  SGW_CONFIG_PATH="${SGW_CONFIG_PATH:-/opt/sync_gateway/etc/sync_gateway.json}"
else
  echo "Native systemd unit detected."
  SGW_CONFIG_PATH=$(systemctl cat sync_gateway 2>/dev/null | grep -oE '/\S+\.json' | head -n1)
  SGW_CONFIG_PATH="${SGW_CONFIG_PATH:-/home/sync_gateway/sync_gateway.json}"
fi
echo "Using config path: ${SGW_CONFIG_PATH}"

echo "=== [5/8] Deploying bootstrap.json and starting Sync Gateway cleanly ==="
SGW_CONFIG_DIR=$(dirname "${SGW_CONFIG_PATH}")
mkdir -p "${SGW_CONFIG_DIR}"
cp "${MIGRATED_DIR}/bootstrap.json" "${SGW_CONFIG_PATH}"
chown sync_gateway:sync_gateway "${SGW_CONFIG_PATH}" 2>/dev/null || true
echo "Copied ${MIGRATED_DIR}/bootstrap.json -> ${SGW_CONFIG_PATH}"

# Lesson from the 2.1 install: RPM post-install can auto-start the service
# with a stale/example config, outside systemd's own tracking, before ours
# is ever written - `systemctl restart` alone can be a no-op in that case.
# Force a real stop before starting.
systemctl stop sync_gateway 2>/dev/null || true
pkill -f 'sync_gateway' 2>/dev/null || true
sleep 2
rm -f /var/run/sync-gateway.pid 2>/dev/null || true

systemctl enable sync_gateway 2>/dev/null || true
systemctl start sync_gateway

SGW_UP=0
for i in $(seq 1 12); do
  if curl -sf -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" "${SGW_ADMIN_URL}/" > /dev/null 2>&1; then
    SGW_UP=1
    break
  fi
  sleep 5
done
if [ "${SGW_UP}" -ne 1 ]; then
  echo "ERROR: Sync Gateway admin API did not come up within 60s." >&2
  ps -ef | grep sync_gateway | grep -v grep >&2 || true
  journalctl -u sync_gateway -n 60 --no-pager >&2 || true
  exit 1
fi
echo "Sync Gateway node is up."

echo "=== [6/8] Creating/updating database(s) from ${MIGRATED_DIR} ==="
for db_config_file in "${DB_CONFIG_FILES[@]}"; do
  db_name=$(basename "${db_config_file}" .json)
  db_name="${db_name#db-config-}"

  echo "-- Database: ${db_name} --"
  if curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" "${SGW_ADMIN_URL}/${db_name}/" | grep '"db_name"' > /dev/null; then
    echo "  Already exists and online - skipping creation."
    echo "  (Config may differ from ${db_config_file} if the database was created some"
    echo "  other way - this script doesn't attempt to reconcile that, only to avoid"
    echo "  erroring on a database that's already there.)"
  else
    db_status=$(curl -s -o /tmp/db_create_${db_name}.json -w '%{http_code}' \
      -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
      -X PUT "${SGW_ADMIN_URL}/${db_name}/" \
      -H "Content-Type: application/json" \
      -d @"${db_config_file}")
    if [ "${db_status}" = "200" ] || [ "${db_status}" = "201" ]; then
      echo "  Created (HTTP ${db_status})."
    elif [ "${db_status}" = "409" ]; then
      echo "  Already exists (HTTP 409) - treating as success."
    else
      echo "  ERROR: HTTP ${db_status}:" >&2
      cat /tmp/db_create_${db_name}.json >&2
      echo >&2
      rm -f /tmp/db_create_${db_name}.json
      exit 1
    fi
    rm -f /tmp/db_create_${db_name}.json
  fi

  echo "-- Waiting for ${db_name} to report online --"
  DB_ONLINE=0
  for i in $(seq 1 6); do
    if curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" "${SGW_ADMIN_URL}/${db_name}/" | grep '"db_name"' > /dev/null; then
      DB_ONLINE=1
      break
    fi
    sleep 5
  done
  if [ "${DB_ONLINE}" -ne 1 ]; then
    echo "  WARNING: ${db_name} did not report online after 30s." >&2
    curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" "${SGW_ADMIN_URL}/${db_name}/" >&2 || true
    journalctl -u sync_gateway -n 40 --no-pager >&2 || true
  fi
done

echo "=== [7/8] Creating/updating users ==="
for db_config_file in "${DB_CONFIG_FILES[@]}"; do
  db_name=$(basename "${db_config_file}" .json)
  db_name="${db_name#db-config-}"
  users_file="${MIGRATED_DIR}/users-${db_name}.json"

  if [ ! -f "${users_file}" ]; then
    echo "-- No users file for ${db_name} (${users_file} not found) - skipping. --"
    continue
  fi

  echo "-- Users for ${db_name} (from ${users_file}) --"
  # Iterate the users JSON with python3 so each user's config is PUT
  # individually with correct status checking, rather than assuming shape.
  python3 -c "
import json, subprocess, sys
with open('${users_file}') as f:
    users = json.load(f)
for name, conf in users.items():
    payload = json.dumps(conf)
    result = subprocess.run(
        ['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
         '-u', '${CB_ADMIN_USER}:${CB_ADMIN_PASS}',
         '-X', 'PUT', '${SGW_ADMIN_URL}/${db_name}/_user/' + name,
         '-H', 'Content-Type: application/json', '-d', payload],
        capture_output=True, text=True
    )
    status = result.stdout.strip()
    ok = status in ('200', '201')
    print(f'  {name}: HTTP {status}' + ('' if ok else ' -- CHECK THIS'))
"
done

echo "=== [8/8] Summary ==="
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "<unavailable>")

{
  echo "Sync Gateway ${SGW_VERSION} is provisioned on this machine (Oracle Linux 8),"
  echo "pointed at Couchbase Server at ${CB_HOST}, configured from ${MIGRATED_DIR}."
  echo ""
  echo "Public API:  http://${PUBLIC_IP}:4984"
  echo "Admin API:   http://${PUBLIC_IP}:4985"
  echo "Config path actually used: ${SGW_CONFIG_PATH}"
  echo "Databases:"
  for db_config_file in "${DB_CONFIG_FILES[@]}"; do
    db_name=$(basename "${db_config_file}" .json)
    db_name="${db_name#db-config-}"
    echo "  - ${db_name}"
  done
  echo ""
  echo "This script is safe to re-run - see /var/log/sgw-4.1-install.log for full history."
} > /home/ec2-user/SGW_4.1_READY.txt
chown ec2-user:ec2-user /home/ec2-user/SGW_4.1_READY.txt

echo "############# Run finished: $(date -u '+%Y-%m-%dT%H:%M:%SZ') #############"
echo "=== Done. See /home/ec2-user/SGW_4.1_READY.txt for details. ==="
