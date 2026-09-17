#!/usr/bin/env bash
# Compatibility wrapper: YouTube + TikTok through the universal coordinator.
# Because their native aspect ratios differ, the planner creates 16:9 and 9:16
# canvases as needed; compatible targets still share encoders automatically.
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export STREAM_TARGETS=youtube,tiktok
rm -f "$BASE_DIR/runtime/targets.env"
exec "$BASE_DIR/scripts/stream_multi.sh"
