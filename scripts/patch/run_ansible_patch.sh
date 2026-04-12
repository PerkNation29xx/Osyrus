#!/usr/bin/env bash
set -euo pipefail

JOB_ID="${JOB_ID:-0}"
TARGET_IP="${TARGET_IP:-}"
TARGET_NAME="${TARGET_NAME:-}"
TARGET_TYPE="${TARGET_TYPE:-unknown}"
HOST_ALIAS="${HOST_ALIAS:-}"
CVE_ID="${CVE_ID:-}"
SNAPSHOT_REQUIRED="${SNAPSHOT_REQUIRED:-false}"
CLONE_VM="${CLONE_VM:-false}"
ROLLBACK_STRATEGY="${ROLLBACK_STRATEGY:-manual_restore_required}"
EXECUTION_MODE="${EXECUTION_MODE:-dry-run}"
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-ansible/playbooks/osyrus_patch_workflow.yml}"
ANSIBLE_INVENTORY="${ANSIBLE_INVENTORY:-ansible/inventory/hosts.ini}"
ANSIBLE_BIN="${ANSIBLE_BIN:-ansible-playbook}"

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

if [[ -z "$TARGET_IP" ]]; then
  echo "[ERROR] TARGET_IP is required"
  exit 2
fi

echo "[INFO] Osyrus patch workflow"
echo "[INFO] Job ID: ${JOB_ID}"
echo "[INFO] Target: ${TARGET_NAME:-unknown} (${TARGET_IP}) type=${TARGET_TYPE}"
echo "[INFO] Host alias: ${HOST_ALIAS:-n/a}"
echo "[INFO] CVE: ${CVE_ID:-n/a}"
echo "[INFO] Snapshot required: ${SNAPSHOT_REQUIRED}"
echo "[INFO] Clone VM: ${CLONE_VM}"
echo "[INFO] Rollback strategy: ${ROLLBACK_STRATEGY}"
echo "[INFO] Mode: ${EXECUTION_MODE}"

if [[ ! -f "$ANSIBLE_PLAYBOOK" ]]; then
  echo "[ERROR] Playbook not found: $ANSIBLE_PLAYBOOK"
  exit 3
fi

if [[ "${EXECUTION_MODE}" == "dry-run" ]]; then
  echo "[DRY-RUN] Would execute ansible playbook now."
  echo "[DRY-RUN] Playbook: ${ANSIBLE_PLAYBOOK}"
  echo "[DRY-RUN] Inventory: ${ANSIBLE_INVENTORY}"
  exit 0
fi

if ! command -v "$ANSIBLE_BIN" >/dev/null 2>&1; then
  echo "[ERROR] ${ANSIBLE_BIN} is not installed"
  exit 4
fi

INVENTORY_ARG=()
if [[ -f "$ANSIBLE_INVENTORY" ]]; then
  INVENTORY_ARG=(-i "$ANSIBLE_INVENTORY")
else
  echo "[WARN] Inventory file not found; using dynamic single-host inventory"
  INVENTORY_ARG=(-i "${TARGET_IP},")
fi

EXTRA_VARS_JSON="$(cat <<EOF
{"target_ip":"$(json_escape "${TARGET_IP}")","target_name":"$(json_escape "${TARGET_NAME}")","target_type":"$(json_escape "${TARGET_TYPE}")","host_alias":"$(json_escape "${HOST_ALIAS}")","cve_id":"$(json_escape "${CVE_ID}")","snapshot_required":"$(json_escape "${SNAPSHOT_REQUIRED}")","clone_requested":"$(json_escape "${CLONE_VM}")","rollback_strategy":"$(json_escape "${ROLLBACK_STRATEGY}")"}
EOF
)"

set -x
"$ANSIBLE_BIN" \
  "${INVENTORY_ARG[@]}" \
  "$ANSIBLE_PLAYBOOK" \
  --limit "${TARGET_IP}" \
  --extra-vars "${EXTRA_VARS_JSON}"
set +x

echo "[INFO] Patch workflow execution complete"
