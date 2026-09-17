#!/usr/bin/env bash
# Compatibility wrapper: universal engine, YouTube only.
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export STREAM_TARGETS=youtube
rm -f "$BASE_DIR/runtime/targets.env"
exec "$BASE_DIR/scripts/stream_multi.sh"
