#!/bin/bash
# ============================================================================
# CA-signed X.509 certificates for the Couchbase 8.0.3 cluster.
#
# Replaces each node's out-of-the-box self-signed certificate with one signed
# by a CA. This removes the "Out-of-the-box certificates are self-signed"
# warning and lets clients (Sync Gateway, SDKs, XDCR) verify the nodes.
#
# COMMANDS
#   generate [addr...]  Run on your laptop or an admin box, NOT on the nodes.
#                       Creates a CA in ./ca if there isn't one, and a
#                       certificate for every node in ./certs/<addr>/.
#                       Addresses default to NODES in cb-8.0.3-cluster-ol8.sh.
#                       Re-run any time (e.g. after adding a node): only
#                       missing, expiring or invalid certificates are issued.
#
#   install <addr>      Run ON a node, as root. Called by the cluster script
#                       when CUSTOM_CERTS="true". Trusts certs/ca.pem and
#                       installs certs/<addr>/ as the node certificate. Does
#                       nothing if that certificate is already the live one.
#
# DISTRIBUTION
#   Certificates are written to CERT_DIR from the cluster script's CONFIG
#   block (default ./certs). Copy that folder - NOT ./ca, which holds the CA
#   private key - next to the cluster script on every node.
#
# USING YOUR OWN PKI
#   Skip "generate". Put the CA certificate at certs/ca.pem and, per node,
#   certs/<node-addr>/chain.pem (node cert, then any intermediates) and
#   certs/<node-addr>/pkey.key (unencrypted private key). The certificate's
#   subject alternative names must include the node's address from NODES.
#
# Works with macOS (LibreSSL) and Linux (OpenSSL) openssl.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_SCRIPT="${SCRIPT_DIR}/cb-8.0.3-cluster-ol8.sh"
CA_DIR="${CA_DIR:-${SCRIPT_DIR}/ca}"
# CERT_DIR comes from the cluster script's CONFIG block (asked via
# --print-cert-dir, so bash itself reads the config). An explicit CERT_DIR
# environment variable wins - the cluster script passes one when it calls
# "install" on a node.
if [ -z "${CERT_DIR:-}" ]; then
  [ -f "${CLUSTER_SCRIPT}" ] || { echo "ERROR: ${CLUSTER_SCRIPT} not found. Set CERT_DIR explicitly." >&2; exit 1; }
  CERT_DIR=$(bash "${CLUSTER_SCRIPT}" --print-cert-dir)
fi
case "${CERT_DIR}" in /*) ;; *) CERT_DIR="${SCRIPT_DIR}/${CERT_DIR}" ;; esac
CA_NAME="Couchbase Cluster CA"
CA_DAYS=7300          # CA lifetime (20 years) - must outlast every node cert it signs
NODE_DAYS=3650        # node certificate lifetime (10 years)
RENEW_DAYS=30         # re-issue node certificates this close to expiry

CB_ADMIN_USER="${CB_ADMIN_USER:-Administrator}"
CB_ADMIN_PASS="${CB_ADMIN_PASS:-password123}"
CB_CLI="/opt/couchbase/bin/couchbase-cli"
CB_INBOX="/opt/couchbase/var/lib/couchbase/inbox"

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

# ---------------------------------------------------------------- helpers ---

is_ip() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# Fingerprint of the first (leaf) certificate in a PEM file or on stdin.
fingerprint() { openssl x509 -noout -fingerprint -sha256 ${1:+-in "$1"} 2>/dev/null | cut -d= -f2; }

# cert_ok <ca.pem> <node dir> <addr> - true if the node certificate exists,
# chains to this CA, matches its key, names <addr>, and isn't near expiry.
cert_ok() {
  local ca=$1 dir=$2 addr=$3 san
  [ -f "${dir}/chain.pem" ] && [ -f "${dir}/pkey.key" ] || return 1
  openssl verify -CAfile "${ca}" -untrusted "${dir}/chain.pem" "${dir}/chain.pem" > /dev/null 2>&1 || return 1
  openssl x509 -noout -checkend $(( RENEW_DAYS * 86400 )) -in "${dir}/chain.pem" > /dev/null || return 1
  [ "$(openssl x509 -noout -modulus -in "${dir}/chain.pem" | openssl sha256)" = \
    "$(openssl rsa -noout -modulus -in "${dir}/pkey.key" 2>/dev/null | openssl sha256)" ] || return 1
  if is_ip "${addr}"; then san="IP Address:${addr}"; else san="DNS:${addr}"; fi
  openssl x509 -noout -text -in "${dir}/chain.pem" | grep -Eq "${san//./\\.}(,|$)"
}

# Node addresses from NODES in the cluster script, so there is one list.
# The cluster script prints them itself, so comments and formatting in its
# CONFIG block behave exactly as bash reads them.
nodes_from_cluster_script() {
  [ -f "${CLUSTER_SCRIPT}" ] || die "Cannot find ${CLUSTER_SCRIPT}. Pass node addresses as arguments instead."
  bash "${CLUSTER_SCRIPT}" --print-nodes
}

# --------------------------------------------------------------- generate ---

ensure_ca() {
  if [ -f "${CA_DIR}/ca.key" ] && [ -f "${CA_DIR}/ca.pem" ]; then
    echo "CA already exists: ${CA_DIR}/ca.pem"
  elif [ -e "${CA_DIR}/ca.key" ] || [ -e "${CA_DIR}/ca.pem" ]; then
    die "Only one of ca.key / ca.pem is in ${CA_DIR}. Restore the other, or remove both to create a new CA."
  elif [ -f "${CERT_DIR}/ca.pem" ]; then
    # certs/ was made by an existing CA, but that CA isn't here. Creating a
    # new one would silently invalidate every node certificate already issued.
    die "${CERT_DIR}/ca.pem exists but the CA (${CA_DIR}/ca.key, ca.pem) is not on this machine. Copy the ca/ folder from where you first ran 'generate'. To deliberately start over with a new CA, remove ${CERT_DIR} first."
  else
    echo "Creating CA in ${CA_DIR}"
    mkdir -p "${CA_DIR}" && chmod 700 "${CA_DIR}"
    cat > "${CA_DIR}/ca.cnf" << EOF
[req]
distinguished_name = dn
x509_extensions    = v3_ca
prompt             = no
[dn]
CN = ${CA_NAME}
[v3_ca]
basicConstraints     = critical, CA:TRUE
keyUsage             = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
    (umask 077 && openssl genrsa -out "${CA_DIR}/ca.key" 4096 2>/dev/null)
    openssl req -x509 -new -config "${CA_DIR}/ca.cnf" -key "${CA_DIR}/ca.key" \
      -sha256 -days "${CA_DAYS}" -out "${CA_DIR}/ca.pem"
  fi
  mkdir -p "${CERT_DIR}"
  cmp -s "${CA_DIR}/ca.pem" "${CERT_DIR}/ca.pem" 2>/dev/null || cp "${CA_DIR}/ca.pem" "${CERT_DIR}/ca.pem"
}

issue_node_cert() {
  local addr=$1 dir="${CERT_DIR}/$1" san work
  if is_ip "${addr}"; then san="IP:${addr}"; else san="DNS:${addr}"; fi
  work=$(mktemp -d)
  cat > "${work}/ext.cnf" << EOF
basicConstraints = CA:FALSE
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName   = ${san}
EOF
  mkdir -p "${dir}"
  (umask 077 && openssl genrsa -out "${work}/pkey.key" 2048 2>/dev/null)
  openssl req -new -key "${work}/pkey.key" -subj "/CN=${addr}" -out "${work}/node.csr"
  openssl x509 -req -in "${work}/node.csr" -CA "${CA_DIR}/ca.pem" -CAkey "${CA_DIR}/ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" -days "${NODE_DAYS}" -sha256 \
    -extfile "${work}/ext.cnf" -out "${work}/chain.pem" 2>/dev/null
  # Replace both files together, so a failed run never leaves a mismatched pair.
  mv "${work}/pkey.key" "${dir}/pkey.key"
  mv "${work}/chain.pem" "${dir}/chain.pem"
  rm -rf "${work}"
}

cmd_generate() {
  command -v openssl > /dev/null || die "openssl is not installed."
  local addrs addr
  if [ $# -gt 0 ]; then addrs="$*"; else addrs=$(nodes_from_cluster_script); fi
  [ -n "${addrs}" ] || die "No node addresses found."

  ensure_ca
  for addr in ${addrs}; do
    is_ip "${addr}" && warn "${addr} is an IP address, so its certificate gets an IP SAN. DNS names in NODES are recommended (see README)." 
    if cert_ok "${CA_DIR}/ca.pem" "${CERT_DIR}/${addr}" "${addr}"; then
      echo "  ${addr}: valid certificate, skipping."
    else
      echo "  ${addr}: issuing certificate."
      issue_node_cert "${addr}"
    fi
  done

  echo ""
  echo "Done. Copy ${CERT_DIR} next to the cluster script on every node, for example:"
  echo "  scp -r ${CERT_DIR} ec2-user@<node>:~/"
  echo "Keep ${CA_DIR} private - it holds the CA key. Do not copy it to the nodes."
}

# ---------------------------------------------------------------- install ---

ssl_manage() { "${CB_CLI}" ssl-manage -c localhost:8091 -u "${CB_ADMIN_USER}" -p "${CB_ADMIN_PASS}" "$@"; }

# ca_trusted <ca.pem> - true if Couchbase already lists this CA as trusted.
# Compares certificate bodies, ignoring line breaks and whitespace.
ca_trusted() {
  ssl_manage --cluster-ca-info 2>/dev/null | python3 -c '
import sys, json, re
body = lambda pem: re.sub(r"\s+", "", pem.replace("-----BEGIN CERTIFICATE-----", "").replace("-----END CERTIFICATE-----", ""))
want = body(open(sys.argv[1]).read())
try:
    cas = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
sys.exit(0 if any(body(c.get("pem", "")) == want for c in cas) else 1)
' "$1"
}

cmd_install() {
  local addr=${1:-} dir want live
  [ -n "${addr}" ] || die "Usage: $0 install <node-address>"
  [ "$(id -u)" -eq 0 ] || die "install must run as root."
  dir="${CERT_DIR}/${addr}"
  [ -f "${CERT_DIR}/ca.pem" ] && [ -f "${dir}/chain.pem" ] && [ -f "${dir}/pkey.key" ] ||
    die "Missing ${CERT_DIR}/ca.pem or ${dir}/{chain.pem,pkey.key}. Run './cb-certs.sh generate' on your laptop and copy the certs folder to this node."
  cert_ok "${CERT_DIR}/ca.pem" "${dir}" "${addr}" ||
    die "The certificate in ${dir} is invalid for ${addr}: wrong CA, key mismatch, missing address, or expiring within ${RENEW_DAYS} days. Re-run 'generate' and copy it again."

  want=$(fingerprint "${dir}/chain.pem")
  live=$(openssl s_client -connect localhost:18091 < /dev/null 2>/dev/null | fingerprint || true)
  if [ "${live}" = "${want}" ]; then
    echo "Node certificate for ${addr} is already active, skipping."
    return 0
  fi

  echo "Installing CA-signed certificate for ${addr}."
  mkdir -p "${CB_INBOX}/CA"
  install -o couchbase -g couchbase -m 644 "${CERT_DIR}/ca.pem" "${CB_INBOX}/CA/ca.pem"
  install -o couchbase -g couchbase -m 600 "${dir}/chain.pem" "${CB_INBOX}/chain.pem"
  install -o couchbase -g couchbase -m 600 "${dir}/pkey.key"  "${CB_INBOX}/pkey.key"
  chown couchbase:couchbase "${CB_INBOX}" "${CB_INBOX}/CA"

  if ca_trusted "${CERT_DIR}/ca.pem"; then
    echo "CA is already trusted by the cluster."
  else
    echo "Loading CA into the cluster's trusted CAs."
    ssl_manage --cluster-ca-load
    # --set-node-certificate below fails loudly if the CA isn't trusted, so a
    # mismatch here (e.g. a different output format) is only a warning.
    ca_trusted "${CERT_DIR}/ca.pem" || warn "Couchbase doesn't list the CA as trusted yet; the next step will confirm."
  fi
  ssl_manage --set-node-certificate

  live=$(openssl s_client -connect localhost:18091 < /dev/null 2>/dev/null | fingerprint || true)
  [ "${live}" = "${want}" ] || die "Couchbase accepted the certificate but port 18091 is not serving it yet. Check /opt/couchbase/var/lib/couchbase/logs/error.log."
  echo "Node certificate for ${addr} is active."
}

# ------------------------------------------------------------------- main ---

case "${1:-}" in
  generate) shift; cmd_generate "$@" ;;
  install)  shift; cmd_install "$@" ;;
  *) sed -n '2,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
