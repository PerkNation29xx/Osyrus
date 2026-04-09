#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL_SECONDS="${1:-60}"
cd "$SCRIPT_DIR"
exec ./watch_inventory.sh "$INTERVAL_SECONDS"
