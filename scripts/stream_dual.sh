#!/usr/bin/env bash
# Compatibility wrapper: YouTube + TikTok through ONE shared render/encode.
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export STREAM_TARGETS=youtube,tiktok
rm -f "$BASE_DIR/runtime/targets.env"
exec "$BASE_DIR/scripts/stream_multi.sh"
