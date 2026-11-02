#!/bin/bash
# ============================================================================
# Couchbase Server 8.0.3 - MULTI-NODE cluster install + provisioning.
# Oracle Linux 8 target. Cluster-capable successor to cb-8.0.3-ol8.sh.
#
# HOW IT WORKS
#   Run this SAME script (same CONFIG block) on every node, as EC2 user-data
#   or by hand, in any order. Each node finds itself in NODES by its IP /
#   hostname and does the right thing:
#     - FIRST node in NODES (the "bootstrap" node): initialises the cluster,
#       rebalances in any nodes that have already joined, then creates
#       buckets and RBAC users. It does NOT wait for the other nodes.
#     - Every OTHER node: installs Couchbase, waits for the bootstrap node
#       to be initialised, adds itself with the services listed for it,
#       then rebalances itself in.
#
#   All of the settings you would normally change are in the CONFIG block
#   below. Nothing under "END CONFIG" should need editing.
#
# NETWORK: nodes must reach each other on the Couchbase ports. On EC2, the
#   simplest option is one security group that allows all TCP traffic from
#   itself. If firewalld is running, this script opens the ports for you.
#   Full list of inbound rules: README.md, "2. Network: inbound rules".
#
# IDEMPOTENT / SAFE TO RE-RUN: every step checks its own state first. To
#   grow the cluster, add a line to NODES and run the script on the new
#   node - it joins and rebalances itself in. Re-running on the bootstrap
#   node re-applies the memory quotas and bucket RAM sizes.
#
# Usage: sudo bash cb-8.0.3-cluster-ol8.sh
#        sudo THIS_NODE=10.0.1.11 bash cb-8.0.3-cluster-ol8.sh   # force identity
#        bash cb-8.0.3-cluster-ol8.sh --print-nodes      # node addresses, one per line
#        bash cb-8.0.3-cluster-ol8.sh --print-cert-dir   # resolved CERT_DIR
# ============================================================================
set -euo pipefail

############################## CONFIG - EDIT HERE ##############################

CB_VERSION="8.0.3"
CLUSTER_NAME="securus-prod-8.0.3"
ADMIN_USER="Administrator"
ADMIN_PASS="password"

# One line per node:  "<address>|<services>"
#   address  - the DNS name (recommended) or private IP the other nodes use
#              to reach this one. The node registers itself in the cluster
#              under this name, it is fixed once the node joins, and it is
#              the name put in the node's certificate (CUSTOM_CERTS). DNS
#              names must resolve to the node's private IP on every node.
#   services - comma-separated list of:
#              data,index,query,fts,eventing,analytics,backup
# The FIRST line is the bootstrap node and must include "data".
NODES=(
  "ip-172-31-22-91.us-west-1.compute.internal|data"
  "ip-172-31-23-78.us-west-1.compute.internal|data"
  "ip-172-31-22-94.us-west-1.compute.internal|index,query"
)

# Memory quota per node, in MB, for each service. A quota only applies to
# nodes that run that service. Quotas for services not used in NODES are ignored.
DATA_RAM_MB=1024
INDEX_RAM_MB=1024
FTS_RAM_MB=512
EVENTING_RAM_MB=256
ANALYTICS_RAM_MB=1024
INDEX_STORAGE="default"          # default (Plasma) | memopt

# One line per bucket:  "<name>|<RAM MB per data node>|<replicas>|<backend>"
#   backend - couchstore | magma. Couchstore always has 1024 vBuckets.
#             Magma buckets are created with 1024 vBuckets rather than the
#             8.0 default of 128, so they can receive XDCR from the pre-8.0
#             cluster.
# The RAM values of all buckets added together must fit within DATA_RAM_MB.
BUCKETS=(
  "threads|512|1|couchstore"
)

# One line per RBAC user:  "<username>|<password>|<roles>"
# (If a role list contains commas, it is still a single field.)
#   {BUCKETS} in a role expands to one role per bucket in BUCKETS, so
#   bucket_full_access[{BUCKETS}] covers every bucket above - one or many -
#   and follows renames. To limit a user to some buckets, name them:
#   bucket_full_access[threads],bucket_full_access[orders]
# Every bucket a role names must be in BUCKETS (checked before installing).
USERS=(
  "sync_gateway|sgpassword123|bucket_full_access[{BUCKETS}]"
)

# Where each node keeps its data and its indexes. Couchbase best practice is
# a separate disk (EBS volume) for each, so writes and index builds don't
# compete for I/O. Mount a volume at the path the node uses (DATA_PATH on
# data nodes, INDEX_PATH on index nodes) BEFORE the script runs. The folders
# are created if they don't exist, so the script still works on a single
# disk (you get a warning). Paths are fixed once a node joins a cluster, so
# decide before the first run. Set to "" for the Couchbase default
# (/opt/couchbase/var/lib/couchbase/data).
DATA_PATH="/opt/couchbase/var/data"
INDEX_PATH="/opt/couchbase/var/index"

# How long a joining node waits for the bootstrap node to be initialised,
# in minutes. (The bootstrap node never waits for the others.)
JOIN_TIMEOUT_MIN=30

# The old 7.0.3 cluster. Used only to print the XDCR commands to run there.
OLD_CLUSTER_HOST=""

# CA-signed node certificates instead of Couchbase's self-signed ones (see
# cb-certs.sh). Before setting "true": run "./cb-certs.sh generate" on your
# laptop, then copy CERT_DIR and cb-certs.sh next to this script on every
# node. Can be turned on for an existing cluster: re-run the script on every
# node, bootstrap first.
CUSTOM_CERTS="true"
# Where the certificates live. "./cb-certs.sh generate" reads this setting
# and writes here, and each node installs its certificate from here. A
# relative path is relative to the folder holding the scripts.
CERT_DIR="certs"

################################## END CONFIG ##################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${CERT_DIR}" in /*) ;; *) CERT_DIR="${SCRIPT_DIR}/${CERT_DIR}" ;; esac

# Query options: print a CONFIG value and exit without logging, installing
# or needing root. Used by cb-certs.sh so the CONFIG block stays the single
# source of truth. Safe to run anywhere, including a laptop.
case "${1:-}" in
  --print-nodes)    for entry in "${NODES[@]}"; do echo "${entry%%|*}"; done; exit 0 ;;
  --print-cert-dir) echo "${CERT_DIR}"; exit 0 ;;
  "") ;;
  *) echo "Usage: $0 [--print-nodes | --print-cert-dir]" >&2; exit 1 ;;
esac

exec > >(tee -a "/var/log/cb-${CB_VERSION}-cluster-install.log") 2>&1
echo "############# Run started: $(date -u '+%Y-%m-%dT%H:%M:%SZ') #############"
CB_BIN="/opt/couchbase/bin"
CLI="${CB_BIN}/couchbase-cli"
AUTH=(-u "${ADMIN_USER}" -p "${ADMIN_PASS}")

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

# ---------------------------------------------------------------- helpers ---

# HTTP status of a URL; "000" if unreachable. Extra args go to curl.
http_status() {
  curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$@" 2>/dev/null || true
}

pools_json() {
  curl -s --connect-timeout 5 --max-time 15 -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "http://$1:8091/pools/default" 2>/dev/null || true
}

# Prints "<address> <membership>" for every node the cluster knows about.
cluster_members() {
  pools_json "$1" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for n in d.get("nodes", []):
    print(n["hostname"].rsplit(":", 1)[0], n.get("clusterMembership", ""))
'
}

is_member()           { cluster_members "$1" | awk -v h="$2" '$1 == h { f = 1 } END { exit !f }'; }
# Initialised = /pools now demands auth AND our credentials are accepted.
cluster_initialized() {
  [ "$(http_status "http://$1:8091/pools")" = "401" ] &&
  [ "$(http_status -u "${ADMIN_USER}:${ADMIN_PASS}" "http://$1:8091/pools/default")" = "200" ]
}


needs_rebalance() {
  pools_json "${BOOTSTRAP}" | python3 -c '
import sys, json
d = json.load(sys.stdin)
pending = any(n.get("clusterMembership") != "active" for n in d.get("nodes", []))
sys.exit(0 if pending or d.get("balanced") is False else 1)
' 2>/dev/null
}

rebalance_idle() {
  curl -s --max-time 10 -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "http://${BOOTSTRAP}:8091/pools/default/rebalanceProgress" 2>/dev/null \
    | python3 -c 'import sys, json; sys.exit(0 if json.load(sys.stdin).get("status") == "none" else 1)' 2>/dev/null
}

# retry <function> [args] - runs it up to 5 times, first waiting out any
# running rebalance. Several nodes can act at once, and Couchbase refuses to
# add nodes or change buckets while a rebalance is running. Each function
# re-checks its own state, so a retry after partial success is harmless.
retry() {
  local attempt
  for attempt in 1 2 3 4 5; do
    wait_until "the running rebalance to finish" 120 rebalance_idle \
      || die "A rebalance is still running after 2 hours."
    "$@" && return 0
    warn "$1 failed (attempt ${attempt}/5), retrying in 30s."
    sleep 30
  done
  die "$1 failed 5 times. Fix the cause above and re-run this script."
}

# The functions below are called through retry, where set -e is not in
# effect, so every step must succeed or return non-zero explicitly.

rebalance_if_needed() {
  if ! needs_rebalance; then echo "Cluster is balanced, no rebalance needed."; return 0; fi
  echo "Rebalancing..."
  "${CLI}" rebalance -c "${BOOTSTRAP}:8091" "${AUTH[@]}" --no-progress-bar
}

join_cluster() {
  if is_member "${BOOTSTRAP}" "${SELF}"; then echo "${SELF} is already a cluster member."; return 0; fi
  # Couchbase 8.0 refuses plain http here; the joining node must be given
  # as https on the TLS management port 18091.
  "${CLI}" server-add -c "${BOOTSTRAP}:8091" "${AUTH[@]}" \
    --server-add "https://${SELF}:18091" \
    --server-add-username "${ADMIN_USER}" --server-add-password "${ADMIN_PASS}" \
    --services "${SELF_SERVICES}"
}

# apply_bucket "<name>|<ram>|<replicas>|<backend>" - creates the bucket, or
# sets its RAM quota if it exists. Replica and backend changes to an
# existing bucket are deliberately left to a human, as they need a rebalance.
apply_bucket() {
  local name ram replicas backend list
  IFS='|' read -r name ram replicas backend <<< "$1"
  list=$("${CLI}" bucket-list -c localhost:8091 "${AUTH[@]}") || return 1
  if grep -xF "${name}" <<< "${list}" > /dev/null; then
    echo "Bucket ${name} exists - setting RAM quota to ${ram} MB."
    "${CLI}" bucket-edit -c localhost:8091 "${AUTH[@]}" --bucket "${name}" --bucket-ramsize "${ram}"
  else
    local args=(--bucket "${name}" --bucket-type couchbase --storage-backend "${backend}"
                --bucket-ramsize "${ram}" --bucket-replica "${replicas}" --enable-flush 1 --wait)
    [ "${backend}" = "magma" ] && args+=(--num-vbuckets 1024)
    echo "Creating bucket ${name} (${ram} MB, ${replicas} replica(s), ${backend})."
    "${CLI}" bucket-create -c localhost:8091 "${AUTH[@]}" "${args[@]}"
  fi
}

# Installs this node's CA-signed certificate via cb-certs.sh. Idempotent:
# cb-certs.sh does nothing if the certificate is already live.
install_certs() {
  [ "${CUSTOM_CERTS}" = "true" ] || return 0
  echo "--- CA-signed node certificate ---"
  CERT_DIR="${CERT_DIR}" CB_ADMIN_USER="${ADMIN_USER}" CB_ADMIN_PASS="${ADMIN_PASS}" \
    bash "${SCRIPT_DIR}/cb-certs.sh" install "${SELF}"
}

# If CERT_DIR is missing but an archive of it was copied instead (e.g.
# certs.tar.gz or certs.zip from the laptop), unpack it into CERT_DIR. Only
# runs when CERT_DIR doesn't exist, so an existing folder is never touched.
unpack_certs() {
  local parent base archive work found
  parent=$(dirname "${CERT_DIR}"); base=$(basename "${CERT_DIR}")
  for archive in "${parent}/${base}.tar.gz" "${parent}/${base}.tgz" "${parent}/${base}.zip" \
                 "${parent}/cert.tar.gz" "${parent}/cert.tgz" "${parent}/cert.zip" ""; do
    [ -f "${archive}" ] && break
  done
  [ -n "${archive}" ] || return 0
  echo "${CERT_DIR} not found - unpacking ${archive}."
  work=$(mktemp -d)
  case "${archive}" in
    *.zip)
      command -v unzip > /dev/null || dnf install -y unzip
      unzip -q "${archive}" -d "${work}" ;;
    *)
      tar -xzf "${archive}" -C "${work}" ;;
  esac
  # Accept a top-level folder (certs/...) or the files at the top level, and
  # skip the __MACOSX folder that macOS Finder adds to zip files.
  found=$(find "${work}" -maxdepth 3 -name ca.pem -not -path '*/__MACOSX/*' | head -n 1)
  if [ -z "${found}" ]; then
    rm -rf "${work}"
    die "${archive} has no ca.pem inside. Re-create it with './cb-certs.sh generate' on your laptop, which writes certs.tar.gz."
  fi
  mv "$(dirname "${found}")" "${CERT_DIR}"
  rm -rf "${work}"
  chmod -R go-rwx "${CERT_DIR}"
}

runs_service() { [[ ",${SELF_SERVICES}," == *",$1,"* ]]; }
disk_of()      { findmnt -n -o SOURCE --target "$1"; }

# prepare_path <dir> <service> - creates the folder owned by couchbase. Disk
# warnings only apply if this node runs <service>, since only then is the
# folder actually used.
prepare_path() {
  mkdir -p "$1"
  chown couchbase:couchbase "$1"
  runs_service "$2" || return 0
  if [ "$(disk_of "$1")" = "$(disk_of /)" ]; then
    warn "$1 is on the root disk. For production, mount a dedicated volume there before the first run."
  fi
  if [ "$2" = "index" ] && runs_service data && [ -n "${DATA_PATH}" ] &&
     [ "$(disk_of "${DATA_PATH}")" = "$(disk_of "$1")" ]; then
    warn "This node runs data and index, and DATA_PATH and INDEX_PATH are on the same disk. Separate volumes give better I/O isolation."
  fi
}

# wait_until "<description>" <minutes> <command...>  - returns 1 on timeout.
wait_until() {
  local desc=$1 deadline=$(( $(date +%s) + $2 * 60 ))
  shift 2
  until "$@"; do
    [ "$(date +%s)" -ge "${deadline}" ] && return 1
    echo "  waiting for ${desc}..."
    sleep 10
  done
}

is_ip() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# Works out which NODES entry is this machine: THIS_NODE if set, otherwise
# match the local IPs / hostnames / EC2 metadata against each NODES entry
# and the IPs it resolves to (so DNS names like cb1.example.internal work).
detect_self() {
  if [ -n "${THIS_NODE:-}" ]; then echo "${THIS_NODE}"; return; fi
  local addrs token a addr
  addrs="$(hostname -I 2>/dev/null) $(hostname -s 2>/dev/null) $(hostname -f 2>/dev/null)"
  token=$(curl -s --connect-timeout 2 --max-time 3 -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null || true)
  if [ -n "${token}" ]; then
    for a in local-ipv4 local-hostname; do
      addrs+=" $(curl -s --connect-timeout 2 --max-time 3 -H "X-aws-ec2-metadata-token: ${token}" \
                   "http://169.254.169.254/latest/meta-data/${a}" 2>/dev/null || true)"
    done
  fi
  local resolved c
  for addr in "${NODE_ADDRS[@]}"; do
    resolved=$(getent ahostsv4 "${addr}" 2>/dev/null | awk '{print $1}' | sort -u || true)
    for a in ${addrs}; do
      for c in "${addr}" ${resolved}; do
        [ "${a}" = "${c}" ] && { echo "${addr}"; return; }
      done
    done
  done
}

# ------------------------------------------------------- parse the config ---

NODE_ADDRS=(); NODE_SERVICES=()
for entry in "${NODES[@]}"; do
  IFS='|' read -r addr services <<< "${entry}"
  NODE_ADDRS+=("${addr}"); NODE_SERVICES+=("${services}")
done
BOOTSTRAP="${NODE_ADDRS[0]}"
ALL_SERVICES=",$(IFS=,; echo "${NODE_SERVICES[*]}"),"
[[ ",${NODE_SERVICES[0]}," == *,data,* ]] || die "The first node in NODES (${BOOTSTRAP}) must run the data service."

bucket_total=0
for entry in "${BUCKETS[@]}"; do
  IFS='|' read -r _ ram _ _ <<< "${entry}"
  bucket_total=$(( bucket_total + ram ))
done
[ "${bucket_total}" -le "${DATA_RAM_MB}" ] || die "Bucket RAM adds up to ${bucket_total} MB, which is more than DATA_RAM_MB (${DATA_RAM_MB} MB)."

BUCKET_NAMES=()
for entry in "${BUCKETS[@]}"; do BUCKET_NAMES+=("${entry%%|*}"); done

# expand_roles "<roles>" - replaces {BUCKETS} in each comma-separated role
# with every bucket name, one role per bucket.
expand_roles() {
  local role b out=()
  IFS=',' read -ra role_list <<< "$1"
  for role in "${role_list[@]}"; do
    if [[ ${role} == *"{BUCKETS}"* ]]; then
      for b in "${BUCKET_NAMES[@]}"; do out+=("${role//"{BUCKETS}"/${b}}"); done
    else
      out+=("${role}")
    fi
  done
  (IFS=,; echo "${out[*]}")
}

# A role on a bucket that isn't created here fails at the very end of the
# run, so catch it now. "*" is Couchbase's all-buckets wildcard.
for entry in "${USERS[@]}"; do
  IFS='|' read -r user _ roles <<< "${entry}"
  IFS=',' read -ra role_list <<< "$(expand_roles "${roles}")"
  for role in "${role_list[@]}"; do
    [[ ${role} =~ \[([^]:]+) ]] || continue
    b="${BASH_REMATCH[1]}"
    [ "${b}" = "*" ] && continue
    [[ " ${BUCKET_NAMES[*]} " == *" ${b} "* ]] ||
      die "USERS entry '${user}' has role ${role}, but bucket '${b}' is not in BUCKETS (${BUCKET_NAMES[*]}). Use {BUCKETS} or a bucket from BUCKETS."
  done
done

# Every DNS name in NODES must resolve here, or joins fail later in less
# obvious ways.
unresolved=""
for addr in "${NODE_ADDRS[@]}"; do
  is_ip "${addr}" || getent hosts "${addr}" > /dev/null || unresolved+=" ${addr}"
done
[ -z "${unresolved}" ] || die "These NODES names do not resolve on this machine:${unresolved}. Create their DNS records (see README, 'DNS names for nodes') and re-run."

SELF=$(detect_self)
[ -n "${SELF}" ] || die "This machine ($(hostname -I 2>/dev/null)) does not match any address in NODES. Fix NODES or set THIS_NODE."
for i in "${!NODE_ADDRS[@]}"; do
  [ "${NODE_ADDRS[$i]}" = "${SELF}" ] && SELF_SERVICES="${NODE_SERVICES[$i]}"
done
if [ "${SELF}" = "${BOOTSTRAP}" ]; then ROLE="bootstrap"; else ROLE="joiner"; fi

# Fail now, not after a 10-minute install, if certificates are missing.
if [ "${CUSTOM_CERTS}" = "true" ]; then
  [ -d "${CERT_DIR}" ] || unpack_certs
  [ -f "${SCRIPT_DIR}/cb-certs.sh" ] || die "CUSTOM_CERTS is true but ${SCRIPT_DIR}/cb-certs.sh is missing. Copy it next to this script."
  [ -f "${CERT_DIR}/ca.pem" ] && [ -f "${CERT_DIR}/${SELF}/chain.pem" ] && [ -f "${CERT_DIR}/${SELF}/pkey.key" ] ||
    die "CUSTOM_CERTS is true but ${CERT_DIR}/ca.pem or ${CERT_DIR}/${SELF}/ is missing. Run './cb-certs.sh generate' on your laptop and copy the certs folder (or certs.tar.gz / certs.zip) here."
fi
echo "This node: ${SELF}  role: ${ROLE}  services: ${SELF_SERVICES}  bootstrap: ${BOOTSTRAP}"

# ------------------------------------------------------------ node setup ----

echo "=== [1/7] Confirm OS and AVX2 CPU support (hard requirement for CBS 8.0+) ==="
if ! grep -qi 'ID="ol"' /etc/os-release || ! grep -q 'PLATFORM_ID="platform:el8"' /etc/os-release; then
  warn "/etc/os-release doesn't look like Oracle Linux 8:"
  cat /etc/os-release
fi
grep -q avx2 /proc/cpuinfo || die "This CPU does not report AVX2 support. Couchbase Server 8.0+ will not start. Pick a current-generation instance type."
echo "AVX2 confirmed present."

echo "=== [2/7] OS prerequisites, kernel tuning, firewall ==="
dnf update -y --exclude='curl*'
dnf install -y wget python3 chrony lsof sysstat net-tools
systemctl enable --now chronyd

# Kernel settings follow the Couchbase docs ("Disabling Transparent Huge
# Pages" and "Swap Space and Kernel Swappiness").

# THP off, as a oneshot unit ordered before couchbase-server so it applies
# before Couchbase starts at boot. The unit file is rewritten if it differs
# (older runs of this script wrote a Type=simple unit with no ordering).
THP_UNIT=/etc/systemd/system/disable_thp.service
THP_UNIT_NEW=$(mktemp)
cat > "${THP_UNIT_NEW}" << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=couchbase-server.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never | tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null'
ExecStart=/bin/sh -c 'echo never | tee /sys/kernel/mm/transparent_hugepage/defrag > /dev/null'

[Install]
WantedBy=basic.target
EOF
if cmp -s "${THP_UNIT_NEW}" "${THP_UNIT}"; then
  rm -f "${THP_UNIT_NEW}"
else
  echo "Writing ${THP_UNIT}."
  mv "${THP_UNIT_NEW}" "${THP_UNIT}"
  chmod 644 "${THP_UNIT}"
  systemctl daemon-reload
  # reenable moves the enable symlink from multi-user.target to basic.target.
  systemctl reenable disable_thp
fi
systemctl enable disable_thp
systemctl start disable_thp

# Swappiness 1, not 0: since kernel 3.5, 0 raises the risk of the OOM killer
# under memory and I/O pressure. A drop-in file is replaced on every run, so
# changing the value here takes effect on re-run. The vm.swappiness=0 line
# that older runs appended to /etc/sysctl.conf is removed, because that file
# is read after /etc/sysctl.d and would override it.
sed -i '/^vm\.swappiness=0$/d' /etc/sysctl.conf
grep -Eq '^[[:space:]]*vm\.swappiness' /etc/sysctl.conf &&
  warn "/etc/sysctl.conf also sets vm.swappiness and overrides /etc/sysctl.d/99-couchbase.conf. Remove it from /etc/sysctl.conf."
{
  echo "# Written by cb-8.0.3-cluster-ol8.sh - Couchbase kernel settings."
  echo "vm.swappiness = 1"
  # Red Hat kernels only (RHEL 8 / Oracle Linux 8 RHCK): makes the setting
  # apply inside cgroups too. Absent on other kernels, so only set if present.
  if [ -e /proc/sys/vm/force_cgroup_v2_swappiness ]; then
    echo "vm.force_cgroup_v2_swappiness = 1"
  fi
} > /etc/sysctl.d/99-couchbase.conf
sysctl --system > /dev/null || warn "sysctl --system reported errors in a sysctl file; the values in effect are checked below."

# tuned profiles can set THP and swappiness themselves (virtual-guest sets
# swappiness to 30), overriding the above. If tuned is running, layer a
# couchbase profile on top of the active one.
if systemctl is-active --quiet tuned; then
  TUNED_ACTIVE=$(tuned-adm active 2>/dev/null | sed -n 's/^Current active profile: //p')
  TUNED_BASE="${TUNED_ACTIVE}"
  if [ "${TUNED_ACTIVE}" = "couchbase" ]; then
    TUNED_BASE=$(sed -n 's/^include=//p' /etc/tuned/couchbase/tuned.conf 2>/dev/null)
  fi
  [ -n "${TUNED_BASE}" ] || TUNED_BASE=$(tuned-adm recommend 2>/dev/null)
  echo "tuned is active (profile: ${TUNED_ACTIVE:-none}) - applying the 'couchbase' profile on top of ${TUNED_BASE:-nothing}."
  mkdir -p /etc/tuned/couchbase
  cat > /etc/tuned/couchbase/tuned.conf << EOF
# Written by cb-8.0.3-cluster-ol8.sh - Couchbase kernel settings.
[main]
${TUNED_BASE:+include=${TUNED_BASE// /,}}

[vm]
transparent_hugepages=never

[sysctl]
vm.swappiness=1
EOF
  tuned-adm profile couchbase
else
  echo "tuned not active - nothing to override."
fi

# Show what is actually in effect, and flag anything that didn't stick.
SWAPPINESS=$(cat /proc/sys/vm/swappiness)
THP_ENABLED=$(cat /sys/kernel/mm/transparent_hugepage/enabled)
THP_DEFRAG=$(cat /sys/kernel/mm/transparent_hugepage/defrag)
echo "vm.swappiness: ${SWAPPINESS}"
[ -e /proc/sys/vm/force_cgroup_v2_swappiness ] &&
  echo "vm.force_cgroup_v2_swappiness: $(cat /proc/sys/vm/force_cgroup_v2_swappiness) (takes full effect after a reboot)"
echo "THP enabled: ${THP_ENABLED}"
echo "THP defrag:  ${THP_DEFRAG}"
[ "${SWAPPINESS}" = "1" ] || warn "vm.swappiness is ${SWAPPINESS}, not 1. Something else on this machine sets it."
[[ ${THP_ENABLED} == *"[never]"* && ${THP_DEFRAG} == *"[never]"* ]] ||
  warn "Transparent Huge Pages are not fully disabled. Check tuned and any other THP setting on this machine."

if systemctl is-active --quiet firewalld; then
  echo "firewalld is active - opening Couchbase node-to-node and client ports."
  for p in 4369 8091-8097 9100-9105 9110-9118 9120-9124 9130 9140 9999 11207-11210 \
           11280 18091-18097 19102 19130 21100 21150 21200 21300; do
    firewall-cmd --permanent --add-port="${p}/tcp" > /dev/null
  done
  firewall-cmd --reload
else
  echo "firewalld not active - relying on the network firewall / security group."
fi

echo "=== [3/7] Installing Couchbase Server ${CB_VERSION} ==="
if rpm -q couchbase-server > /dev/null 2>&1; then
  echo "Couchbase Server already installed ($(rpm -q couchbase-server)), skipping."
else
  cd /tmp
  CB_BASE_URL="https://packages.couchbase.com/releases/${CB_VERSION}"
  # The directory URL always returns 403, so try known exact filenames.
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
      break
    fi
    rm -f "${candidate}"
  done
  [ -n "${CB_RPM}" ] || die "No Couchbase ${CB_VERSION} RPM was downloadable from ${CB_BASE_URL}/. Check couchbase.com/downloads and adjust CB_CANDIDATES."
  dnf install -y "./${CB_RPM}"
fi

echo "=== [4/7] Waiting for local Couchbase Server to accept connections ==="
# 200 = not initialised yet. 401 = already part of a cluster.
local_up() { local s; s=$(http_status http://localhost:8091/pools); [ "${s}" = "200" ] || [ "${s}" = "401" ]; }
if ! wait_until "local Couchbase REST API" 5 local_up; then
  systemctl status couchbase-server --no-pager >&2 || true
  tail -n 50 /opt/couchbase/var/lib/couchbase/logs/babysitter.log >&2 || true
  die "Couchbase Server did not become ready within 5 minutes."
fi
echo "Couchbase Server is ready."

echo "=== [5/7] Node init (hostname + disk paths) ==="
if [ "$(http_status http://localhost:8091/pools)" = "200" ]; then
  NODE_INIT_ARGS=(--node-init-hostname "${SELF}")
  if [ -n "${DATA_PATH}" ]; then
    prepare_path "${DATA_PATH}" data
    NODE_INIT_ARGS+=(--node-init-data-path "${DATA_PATH}")
  fi
  if [ -n "${INDEX_PATH}" ]; then
    prepare_path "${INDEX_PATH}" index
    NODE_INIT_ARGS+=(--node-init-index-path "${INDEX_PATH}")
  fi
  "${CLI}" node-init -c localhost:8091 "${AUTH[@]}" "${NODE_INIT_ARGS[@]}"
else
  echo "Node already initialised, skipping."
  # Paths can't be changed on an initialised node, so only flag a mismatch.
  read -r cur_data cur_index < <(curl -s --max-time 10 -u "${ADMIN_USER}:${ADMIN_PASS}" \
    http://localhost:8091/nodes/self | python3 -c '
import sys, json
hdd = json.load(sys.stdin)["storage"]["hdd"][0]
print(hdd["path"], hdd["index_path"])' 2>/dev/null || true) || true
  [ -n "${DATA_PATH}" ]  && [ -n "${cur_data:-}" ]  && [ "${cur_data}" != "${DATA_PATH}" ] &&
    warn "This node's data path is ${cur_data}, not DATA_PATH (${DATA_PATH}). Changing it needs the node removed, reset and re-added."
  [ -n "${INDEX_PATH}" ] && [ -n "${cur_index:-}" ] && [ "${cur_index}" != "${INDEX_PATH}" ] &&
    warn "This node's index path is ${cur_index}, not INDEX_PATH (${INDEX_PATH}). Changing it needs the node removed, reset and re-added."
  true
fi

# ------------------------------------------------------- cluster formation --

if [ "${ROLE}" = "joiner" ]; then
  echo "=== [6/7] Joining cluster via bootstrap node ${BOOTSTRAP} ==="
  wait_until "bootstrap node ${BOOTSTRAP} to initialise the cluster" "${JOIN_TIMEOUT_MIN}" cluster_initialized "${BOOTSTRAP}" \
    || die "Bootstrap node ${BOOTSTRAP} was not initialised within ${JOIN_TIMEOUT_MIN} min. Re-run this script once it is up."
  # A join needs these ports open in BOTH directions between the nodes. Only
  # this direction can be tested from here, but it catches the usual cause
  # (a security group without an all-TCP-from-itself rule) in seconds.
  blocked=""
  for p in 8091 18091 21100; do
    timeout 3 bash -c "</dev/tcp/${BOOTSTRAP}/${p}" 2>/dev/null || blocked+=" ${p}"
  done
  [ -z "${blocked}" ] || die "Cannot reach bootstrap node ${BOOTSTRAP} on port(s)${blocked}. Nodes need all TCP open between them: check firewalld on both nodes and any network firewall or security group between them, then re-run."
  install_certs
  retry join_cluster
  echo "=== [7/7] Rebalancing this node in ==="
  retry rebalance_if_needed
  echo "Cluster members:"; cluster_members "${BOOTSTRAP}" | sed 's/^/  /'
  echo "############# Run finished: $(date -u '+%Y-%m-%dT%H:%M:%SZ') #############"
  exit 0
fi

echo "=== [6/7] Bootstrap: cluster init, memory quotas, rebalance ==="

QUOTA_ARGS=(--cluster-ramsize "${DATA_RAM_MB}")
[[ ${ALL_SERVICES} == *,index,* ]]     && QUOTA_ARGS+=(--cluster-index-ramsize "${INDEX_RAM_MB}")
[[ ${ALL_SERVICES} == *,fts,* ]]       && QUOTA_ARGS+=(--cluster-fts-ramsize "${FTS_RAM_MB}")
[[ ${ALL_SERVICES} == *,eventing,* ]]  && QUOTA_ARGS+=(--cluster-eventing-ramsize "${EVENTING_RAM_MB}")
[[ ${ALL_SERVICES} == *,analytics,* ]] && QUOTA_ARGS+=(--cluster-analytics-ramsize "${ANALYTICS_RAM_MB}")

if cluster_initialized localhost; then
  echo "Cluster already initialised - re-applying memory quotas from CONFIG."
  retry "${CLI}" setting-cluster -c localhost:8091 "${AUTH[@]}" "${QUOTA_ARGS[@]}"
else
  INIT_ARGS=(--services "${SELF_SERVICES}" --cluster-name "${CLUSTER_NAME}")
  [[ ${ALL_SERVICES} == *,index,* ]] && INIT_ARGS+=(--index-storage-setting "${INDEX_STORAGE}")
  "${CLI}" cluster-init -c localhost:8091 \
    --cluster-username "${ADMIN_USER}" --cluster-password "${ADMIN_PASS}" \
    "${QUOTA_ARGS[@]}" "${INIT_ARGS[@]}"
fi
install_certs

retry rebalance_if_needed
echo "Cluster members:"; cluster_members localhost | sed 's/^/  /'
for addr in "${NODE_ADDRS[@]}"; do
  is_member localhost "${addr}" ||
    echo "  ${addr} has not joined yet - it adds and rebalances itself in when its script runs."
done

echo "=== [7/7] Buckets and RBAC users ==="
for entry in "${BUCKETS[@]}"; do
  retry apply_bucket "${entry}"
done

for entry in "${USERS[@]}"; do
  IFS='|' read -r user pass roles <<< "${entry}"
  roles=$(expand_roles "${roles}")
  echo "Setting RBAC user ${user} (${roles})."
  "${CLI}" user-manage -c localhost:8091 "${AUTH[@]}" \
    --set --rbac-username "${user}" --rbac-password "${pass}" \
    --roles "${roles}" --auth-domain local
done

# ------------------------------------------------------------------ summary --

if [ -n "${OLD_CLUSTER_HOST}" ]; then
  echo ""
  echo "XDCR is created on the SOURCE side. Run these on the old 7.0.3 cluster"
  echo "(xdcr-setup once, then xdcr-replicate once per bucket):"
  echo "  couchbase-cli xdcr-setup -c ${OLD_CLUSTER_HOST}:8091 -u ${ADMIN_USER} -p ${ADMIN_PASS} \\"
  echo "    --create --xdcr-cluster-name new-8.0-cluster --xdcr-hostname ${BOOTSTRAP} \\"
  echo "    --xdcr-username ${ADMIN_USER} --xdcr-password ${ADMIN_PASS} --xdcr-secure-connection none"
  for b in "${BUCKET_NAMES[@]}"; do
    echo "  couchbase-cli xdcr-replicate -c ${OLD_CLUSTER_HOST}:8091 -u ${ADMIN_USER} -p ${ADMIN_PASS} \\"
    echo "    --create --xdcr-cluster-name new-8.0-cluster \\"
    echo "    --xdcr-from-bucket ${b} --xdcr-to-bucket ${b} --xdcr-replication-mode xmem"
  done
fi

# Summary goes to the home of whoever ran sudo; ec2-user or root otherwise.
SUMMARY_USER="${SUDO_USER:-}"
[ -n "${SUMMARY_USER}" ] || { getent passwd ec2-user > /dev/null && SUMMARY_USER=ec2-user || SUMMARY_USER=root; }
SUMMARY_HOME=$(getent passwd "${SUMMARY_USER}" | cut -d: -f6)
{
  echo "Couchbase Server ${CB_VERSION} cluster '${CLUSTER_NAME}' is provisioned."
  echo ""
  echo "Web Console:  via SSH tunnel from your laptop, then http://localhost:8091   (${ADMIN_USER} / ${ADMIN_PASS})"
  echo "              ssh -L 8091:localhost:8091 <user>@<any-node>"
  echo "Nodes:";   printf '  %s\n' "${NODES[@]}"
  echo "Buckets:"; printf '  %s\n' "${BUCKETS[@]}"
  echo "Users:";   for u in "${USERS[@]}"; do echo "  $(echo "${u}" | cut -d'|' -f1)"; done
  echo ""
  echo "Next steps:"
  echo "  1. Set up XDCR from the old cluster (set OLD_CLUSTER_HOST and re-run for exact commands)."
  echo "  2. Run migrate-indexes.sh once data is flowing."
  echo "  3. Run sgw-4.1-ol8.sh on a separate machine, pointed at any node above."
  echo ""
  echo "Safe to re-run. Full log: /var/log/cb-${CB_VERSION}-cluster-install.log"
} > "${SUMMARY_HOME}/CB_${CB_VERSION}_CLUSTER_READY.txt"
chown "${SUMMARY_USER}" "${SUMMARY_HOME}/CB_${CB_VERSION}_CLUSTER_READY.txt"

echo "############# Run finished: $(date -u '+%Y-%m-%dT%H:%M:%SZ') #############"
echo "=== Done. See ${SUMMARY_HOME}/CB_${CB_VERSION}_CLUSTER_READY.txt ==="
