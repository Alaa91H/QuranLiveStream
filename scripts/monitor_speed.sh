#!/usr/bin/env bash
# Backward-compatible entry point for older cron installations.
# The global resource governor now owns encoder-speed/CPU/RAM decisions across
# every active native canvas group, so a separate YouTube-only monitor would be
# both stale and dangerous (it could restart the wrong service).
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec "$BASE_DIR/scripts/resource_governor.sh" --once
