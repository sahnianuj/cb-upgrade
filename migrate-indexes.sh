#!/bin/bash
# ============================================================================
# Migrates index metadata (including the primary index) from an old
# Couchbase Server cluster to a new one, WITHOUT a full document backup/
# restore - uses the same Index Service REST endpoints cbbackupmgr relies
# on internally.
#
# Run this from anywhere that can reach both clusters' port 9102
# (Index Service REST port) - e.g. from either machine, or your own laptop
# if security groups allow it.
#
# Usage:
#   ./migrate-indexes.sh <old-cluster-host> <new-cluster-host> <bucket-name>
#
# Example:
#   ./migrate-indexes.sh 10.0.1.10 10.0.2.20 labdb
# ============================================================================
set -euo pipefail

OLD_HOST="${1:-}"
NEW_HOST="${2:-}"
BUCKET="${3:-}"
ADMIN_USER="${CB_ADMIN_USER:-Administrator}"
ADMIN_PASS="${CB_ADMIN_PASS:-password123}"

if [ -z "${OLD_HOST}" ] || [ -z "${NEW_HOST}" ] || [ -z "${BUCKET}" ]; then
  echo "Usage: $0 <old-cluster-host> <new-cluster-host> <bucket-name>" >&2
  echo "  (set CB_ADMIN_USER / CB_ADMIN_PASS env vars if not Administrator/password123)" >&2
  exit 1
fi

echo "=== Exporting index metadata for bucket '${BUCKET}' from ${OLD_HOST} ==="
export_status=$(curl -s -o /tmp/index-metadata-${BUCKET}.json -w '%{http_code}' \
  -u "${ADMIN_USER}:${ADMIN_PASS}" \
  "http://${OLD_HOST}:9102/getIndexMetadata?bucket=${BUCKET}")

if [ "${export_status}" != "200" ]; then
  echo "ERROR: export failed with HTTP ${export_status}. Response:" >&2
  cat /tmp/index-metadata-${BUCKET}.json >&2
  echo >&2
  echo "Common causes: port 9102 not reachable from here (check security groups), wrong credentials, or no Index Service running on ${OLD_HOST}." >&2
  exit 1
fi

if ! python3 -m json.tool /tmp/index-metadata-${BUCKET}.json > /dev/null 2>&1; then
  echo "ERROR: response from ${OLD_HOST} wasn't valid JSON - something else answered on that port/path. Contents:" >&2
  cat /tmp/index-metadata-${BUCKET}.json >&2
  exit 1
fi

echo "Exported to /tmp/index-metadata-${BUCKET}.json ($(wc -c < /tmp/index-metadata-${BUCKET}.json) bytes)."
echo "Index names found:"
python3 -c "
import json
with open('/tmp/index-metadata-${BUCKET}.json') as f:
    data = json.load(f)
# Structure varies by version - print what we can find defensively rather
# than assume a specific schema shape.
print(json.dumps(data, indent=2)[:2000])
" || echo "(couldn't pretty-print - the raw file is still valid JSON per the check above)"

echo ""
echo "=== Importing index metadata for bucket '${BUCKET}' into ${NEW_HOST} ==="
echo "NOTE: the bucket '${BUCKET}' must already exist on ${NEW_HOST} before this will work."
import_status=$(curl -s -o /tmp/index-restore-${BUCKET}-result.json -w '%{http_code}' \
  -u "${ADMIN_USER}:${ADMIN_PASS}" \
  -X POST "http://${NEW_HOST}:9102/restoreIndexMetadata?bucket=${BUCKET}" \
  -d @/tmp/index-metadata-${BUCKET}.json)

if [ "${import_status}" = "200" ]; then
  echo "SUCCESS: index metadata restored on ${NEW_HOST}."
elif grep -qi 'already exists' /tmp/index-restore-${BUCKET}-result.json 2>/dev/null; then
  echo "Indexes already exist on ${NEW_HOST} (safe to ignore if you're re-running this) - response:"
  cat /tmp/index-restore-${BUCKET}-result.json
else
  echo "ERROR: import failed with HTTP ${import_status}. Response:" >&2
  cat /tmp/index-restore-${BUCKET}-result.json >&2
  echo >&2
  echo "Common causes: bucket name mismatch (must match exactly, including scope/collection if used), bucket doesn't exist yet on ${NEW_HOST}, or the target bucket is still being created." >&2
  exit 1
fi

echo ""
echo "=== Verifying: querying system:indexes on the new cluster ==="
curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
  "http://${NEW_HOST}:8093/query/service" \
  -d "statement=SELECT name, state FROM system:indexes WHERE keyspace_id = \"${BUCKET}\";" \
  | python3 -m json.tool 2>/dev/null || echo "(check manually: cbq -engine=http://${NEW_HOST}:8093 -u ${ADMIN_USER} -p ${ADMIN_PASS} -script='SELECT name, state FROM system:indexes WHERE keyspace_id = \"${BUCKET}\";')"

echo ""
echo "Done. Indexes will show state 'building' until they finish backfilling against"
echo "whatever data currently exists in the bucket (including data still arriving via XDCR)."
