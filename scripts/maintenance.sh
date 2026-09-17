#!/usr/bin/env bash
# Quran Live Stream — Autonomous Scheduled Maintenance & Adaptive Retune
set -Eeuo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE_DIR"
LOG_DIR="$BASE_DIR/logs"; CACHE_DIR="$BASE_DIR/web/.cache"; RUNTIME="$BASE_DIR/runtime"
mkdir -p "$LOG_DIR" "$RUNTIME"
MAINT_LOG="$LOG_DIR/maintenance.log"; SERVICE="quran-live.service"
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] [MAINTENANCE] $*" | tee -a "$MAINT_LOG"; }
log "=== Starting Scheduled Maintenance Run ==="

# 1. Update the branch actually deployed, never force-switch to main.
if [ -d "$BASE_DIR/.git" ]; then
  BRANCH="$(git branch --show-current 2>/dev/null || echo main)"; [ -z "$BRANCH" ] && BRANCH=main
  log "Checking origin/$BRANCH for updates..."
  if git status --porcelain 2>/dev/null | grep -q '^[ MADRCU]'; then
    log "Working tree has local edits; skipping automatic pull."
  else
    git fetch origin "$BRANCH" >/dev/null 2>&1 || true
    BEHIND_COUNT="$(git rev-list "HEAD..origin/$BRANCH" --count 2>/dev/null || echo 0)"
    if [ "$BEHIND_COUNT" -gt 0 ]; then
      log "Applying $BEHIND_COUNT update(s)..."
      git pull --ff-only origin "$BRANCH" >>"$MAINT_LOG" 2>&1 || log "WARNING: pull failed; retry next cycle."
    else log "Repository is up-to-date."; fi
  fi
fi

# 2. Cache + log hygiene.
if [ -d "$CACHE_DIR" ]; then
  DELETED_COUNT="$(find "$CACHE_DIR" -type f -name '*.json' -mtime +7 -delete -print 2>/dev/null | wc -l || echo 0)"
  log "Pruned $DELETED_COUNT stale cache files."
fi
for log_file in "$LOG_DIR"/*.log; do
  [ -f "$log_file" ] || continue
  SIZE_KB="$(du -k "$log_file" | cut -f1)"
  if [ "$SIZE_KB" -gt 5120 ]; then mv "$log_file" "${log_file}.old"; gzip -f "${log_file}.old" 2>/dev/null || true; touch "$log_file"; fi
done

# 3. Weekly clean benchmark/network retune.
env_stale(){
  [ ! -f "$1" ] && return 0
  local mt now; mt="$(stat -c%Y "$1" 2>/dev/null || stat -f%m "$1" 2>/dev/null || echo 0)"
  case "$mt" in ''|*[!0-9]*) return 0;; esac
  now="$(date +%s)"; [ "$((now-mt))" -gt "$((7*86400))" ]
}
RETUNE_DID_STOP=0
if env_stale "$RUNTIME/host.env" || env_stale "$RUNTIME/net.env" || env_stale "$RUNTIME/preflight.env"; then
  if [ -f "$RUNTIME/broadcast_stopped.flag" ]; then
    log "Weekly retune on intentionally idle host; stream will remain stopped."
  else
    log "Weekly retune: stopping universal service for clean measurement."
    systemctl --user stop "$SERVICE" 2>/dev/null || true
    "$BASE_DIR/scripts/stop_ui.sh" >/dev/null 2>&1 || true
    sleep 2; RETUNE_DID_STOP=1
  fi
  "$BASE_DIR/scripts/benchmark_host.sh" --force >>"$MAINT_LOG" 2>&1 || log "WARNING: benchmark failed; old profile retained."
  "$BASE_DIR/scripts/probe_egress.sh" --force >>"$MAINT_LOG" 2>&1 || log "WARNING: egress probe failed."
  rm -f "$RUNTIME/preflight.env" "$RUNTIME/adaptive_rank" "$RUNTIME/ui_profile.sig"
  log "Adaptive state reset to the newly measured host ceiling."
fi

# 4. Daily coordinated refresh releases Chromium/Node fragmentation.
if [ -f "$RUNTIME/broadcast_stopped.flag" ]; then
  log "Broadcast intentionally stopped; no restart."
else
  if systemctl --user cat "$SERVICE" >/dev/null 2>&1; then
    if [ "$RETUNE_DID_STOP" -eq 1 ]; then systemctl --user start "$SERVICE"; else systemctl --user restart "$SERVICE"; fi
    log "Universal service refreshed."
  else
    log "Universal service not installed; running installer."
    "$BASE_DIR/scripts/install_service.sh" >>"$MAINT_LOG" 2>&1 || true
    systemctl --user start "$SERVICE" 2>/dev/null || true
  fi
fi

# Do not force-drop Linux page cache: it is reclaimable memory and dropping it
# creates disk I/O spikes that are harmful to realtime streaming.
log "=== Maintenance Run Successfully Completed ==="
