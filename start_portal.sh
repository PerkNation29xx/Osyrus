#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-8090}"
cd "$SCRIPT_DIR"

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is required to run the portal backend." >&2
  exit 1
fi

./generate_inventory.sh
if [[ -f "./generate_vulnerability_report.py" ]]; then
  ./generate_vulnerability_report.py >/dev/null || true
fi
if [[ -n "${DATABASE_URL:-}" && -f "./scripts/db/seed_from_json.js" ]]; then
  node ./scripts/db/seed_from_json.js --only-if-changed --quiet >/dev/null 2>&1 || true
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use. Try another value, e.g. PORT=8100 ./start_portal.sh" >&2
  exit 1
fi

./watch_inventory.sh 60 &
WATCH_PID=$!
trap 'kill "$WATCH_PID" 2>/dev/null || true' EXIT INT TERM

echo "Portal ready at http://localhost:$PORT"
PORT="$PORT" node ./server.js
