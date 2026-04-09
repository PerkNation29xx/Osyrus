#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-8090}"
cd "$SCRIPT_DIR"
exec python3 -m http.server "$PORT" --bind 0.0.0.0
