#!/usr/bin/env bash
# ==============================================================================
# QuranLiveStream — universal adaptive multi-platform orchestrator
# Selected platforms only. Exact native canvas per aspect group. Shared encoders
# where efficient; split quality groups automatically on capable hardware.
# ==============================================================================
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"; cd "$BASE_DIR"
[ -f .env ] && { set -a; source .env 2>/dev/null; set +a; } || true
source "$BASE_DIR/scripts/platforms.sh"; quran_targets_load
RUNTIME="$BASE_DIR/runtime"; LOG_DIR="$BASE_DIR/logs"; mkdir -p "$RUNTIME/groups" "$LOG_DIR"
LOG="$LOG_DIR/stream.log"; STOP_FLAG="$RUNTIME/broadcast_stopped.flag"
log(){ echo "[$(date '+%F %T')] [MASTER] $*" | tee -a "$LOG"; }

# Resolve effective audio/profile defaults for this host before preflight.
source "$BASE_DIR/scripts/hardware_profile.sh"

# Verify binaries, selected destinations, network reachability and HW encoders.
if ! "$BASE_DIR/scripts/preflight.sh" 2>&1 | tee -a "$LOG"; then
  log "Preflight BLOCKED; refusing to start an invalid broadcast."
  exit 1
fi
[ -f "$RUNTIME/preflight.env" ] && { set -a; source "$RUNTIME/preflight.env" 2>/dev/null || true; set +a; }
AUDIO_MODE="${PREFLIGHT_AUDIO:-${AUDIO_MODE:-pulse}}"; export AUDIO_MODE

# Generate quality/aspect groups from current benchmark + governor state.
"$BASE_DIR/scripts/stream_plan.sh" 2>&1 | tee -a "$LOG"
PLAN="$RUNTIME/stream_plan.tsv"; [ -s "$PLAN" ] || { log "Empty stream plan."; exit 1; }
GROUP_COUNT="$(wc -l < "$PLAN" | tr -d ' ')"; TOTAL_TARGETS=0
while IFS='|' read -r _ _ _ _ _ targets; do IFS=',' read -ra a <<< "$targets"; TOTAL_TARGETS=$((TOTAL_TARGETS+${#a[@]})); done < "$PLAN"
export STREAM_GROUP_COUNT="$GROUP_COUNT" STREAM_TOTAL_TARGETS="$TOTAL_TARGETS"

rm -f "$STOP_FLAG"; touch "$RUNTIME/stream_active.flag"
{
  echo "ACTIVE_TARGETS=$STREAM_TARGETS"
  echo "ACTIVE_GROUPS=$GROUP_COUNT"
  echo "ACTIVE_TARGET_COUNT=$TOTAL_TARGETS"
  echo "ACTIVE_AUDIO=$AUDIO_MODE"
  echo "ACTIVE_TS=$(date +%s)"
  echo "ACTIVE_PLAN=$PLAN"
} > "$RUNTIME/active_profile.env"

PIDS=()
cleanup(){
  touch "$STOP_FLAG"; rm -f "$RUNTIME/stream_active.flag"
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  sleep .5
  for d in "$RUNTIME"/groups/*; do
    [ -d "$d" ] || continue
    kill "$(cat "$d/chrome.pid" 2>/dev/null)" 2>/dev/null || true
    kill "$(cat "$d/xvfb.pid" 2>/dev/null)" 2>/dev/null || true
  done
  kill "$(cat "$RUNTIME/quran-web.pid" 2>/dev/null)" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

idx=0
while IFS='|' read -r group layout profile codec display targets; do
  [ -n "$group" ] || continue
  audio_master=0; [ "$idx" -eq 0 ] && audio_master=1
  log "Launch $group layout=$layout profile=$profile display=:$display targets=$targets"
  env GROUP_AUDIO_MASTER="$audio_master" STREAM_GROUP_COUNT="$GROUP_COUNT" STREAM_TOTAL_TARGETS="$TOTAL_TARGETS" AUDIO_MODE="$AUDIO_MODE" \
    "$BASE_DIR/scripts/stream_worker.sh" "$group" "$layout" "$profile" "$codec" "$display" "$targets" >>"$LOG" 2>&1 &
  PIDS+=("$!"); idx=$((idx+1))
done < "$PLAN"

log "Broadcast active: $TOTAL_TARGETS target(s), $GROUP_COUNT native canvas/encoder group(s), audio=$AUDIO_MODE."

# Any fatal worker exit means its selected platforms are no longer served.
# Exit master so systemd restarts the entire coordinated stack cleanly.
set +e
while [ ! -f "$STOP_FLAG" ]; do
  wait -n "${PIDS[@]}"; EC=$?
  [ -f "$STOP_FLAG" ] && break
  log "A worker exited unexpectedly (code $EC); restarting coordinated stack."
  exit 1
done
set -e
log "Broadcast stop requested."
