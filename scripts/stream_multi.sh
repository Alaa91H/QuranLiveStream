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

# Preflight independently resolves the safe hardware profile. Do NOT source the
# profile here with a user override: a requested profile is only a ceiling and
# must never force weak hardware upward before the planner evaluates it.
if ! "$BASE_DIR/scripts/preflight.sh" 2>&1 | tee -a "$LOG"; then
  log "Preflight BLOCKED; refusing to start an invalid broadcast."
  exit 1
fi
[ -f "$RUNTIME/preflight.env" ] && { set -a; source "$RUNTIME/preflight.env" 2>/dev/null || true; set +a; }
AUDIO_MODE="${PREFLIGHT_AUDIO:-${AUDIO_MODE:-pulse}}"; export AUDIO_MODE

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

PIDS=(); CLEANED=0
cleanup(){
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  touch "$STOP_FLAG"; rm -f "$RUNTIME/stream_active.flag"
  for p in "${PIDS[@]:-}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    kill "$p" 2>/dev/null || true
  done
  # Give worker TERM traps time to reap their exact FFmpeg children before the
  # native canvases disappear underneath x11grab.
  for p in "${PIDS[@]:-}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$p" 2>/dev/null || break; sleep .1; done
  done
  "$BASE_DIR/scripts/stop_ui.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 0' INT TERM

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

# Bash 4.3+ has wait -n; a portable polling fallback keeps older Bash hosts usable.
set +e
while [ ! -f "$STOP_FLAG" ]; do
  if help wait 2>/dev/null | grep -q -- '-n'; then
    wait -n "${PIDS[@]}"; EC=$?
    [ -f "$STOP_FLAG" ] && break
    log "A worker exited unexpectedly (code $EC); restarting coordinated stack."
    exit 1
  fi
  sleep 2
  for p in "${PIDS[@]}"; do
    if ! kill -0 "$p" 2>/dev/null; then
      wait "$p"; EC=$?
      [ -f "$STOP_FLAG" ] && break 2
      log "A worker exited unexpectedly (code $EC); restarting coordinated stack."
      exit 1
    fi
  done
done
set -e
log "Broadcast stop requested."
