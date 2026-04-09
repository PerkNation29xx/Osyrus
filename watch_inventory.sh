#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL_SECONDS="${1:-60}"

cd "$SCRIPT_DIR"

while true; do
  ./generate_inventory.sh >/dev/null
  if [[ -f "./generate_vulnerability_report.py" ]]; then
    ./generate_vulnerability_report.py >/dev/null || true
  fi
  sleep "$INTERVAL_SECONDS"
done
