#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_FILE="${SCRIPT_DIR}/osyrus-web-ha-db-dashboard.json"

GRAFANA_URL="${GRAFANA_URL:-http://grafana.homelab.arpa:3000}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_CREDENTIAL_FILE="${GRAFANA_CREDENTIAL_FILE:-$HOME/.osyrus/credentials/grafana.env}"

if [[ -f "$GRAFANA_CREDENTIAL_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$GRAFANA_CREDENTIAL_FILE"
fi

GRAFANA_PASS="${GRAFANA_PASS:-}"

if [[ ! -f "$DASHBOARD_FILE" ]]; then
  echo "Missing dashboard file: $DASHBOARD_FILE" >&2
  exit 1
fi

if [[ -z "$GRAFANA_PASS" ]]; then
  echo "GRAFANA_PASS is required. Set it in the environment or $GRAFANA_CREDENTIAL_FILE." >&2
  exit 1
fi

payload_file="$(mktemp)"
trap 'rm -f "$payload_file"' EXIT

jq -n \
  --argjson dashboard "$(cat "$DASHBOARD_FILE")" \
  '{dashboard: $dashboard, folderId: 0, overwrite: true, message: "Publish web HA and DB replication dashboard"}' >"$payload_file"

curl -sS -u "$GRAFANA_USER:$GRAFANA_PASS" \
  -H 'Content-Type: application/json' \
  -X POST "$GRAFANA_URL/api/dashboards/db" \
  --data-binary @"$payload_file" | jq
