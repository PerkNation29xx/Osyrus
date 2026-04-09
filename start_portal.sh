#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-8080}"
cd "$SCRIPT_DIR"

./generate_inventory.sh
if [[ -f "./generate_vulnerability_report.py" ]]; then
  ./generate_vulnerability_report.py >/dev/null || true
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use. Try: PORT=8090 ./start_portal.sh" >&2
  exit 1
fi

./watch_inventory.sh 60 &
WATCH_PID=$!
trap 'kill "$WATCH_PID" 2>/dev/null || true' EXIT INT TERM

echo "Portal ready at http://localhost:$PORT"
python3 -m http.server "$PORT"
