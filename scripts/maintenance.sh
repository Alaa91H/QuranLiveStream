#!/usr/bin/env bash
# ==============================================================================
# QuranLiveStream — low-disruption scheduled maintenance
# Updates/cleans/retunes only when needed. No forced page-cache drops and no
# unconditional daily stream restart.
# ==============================================================================
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"; cd "$BASE_DIR"
LOG_DIR="$BASE_DIR/logs"; CACHE_DIR="$BASE_DIR/web/.cache"; RUNTIME="$BASE_DIR/runtime"
mkdir -p "$LOG_DIR" "$RUNTIME"
source "$BASE_DIR/scripts/process_guard.sh"
MAINT_LOG="$LOG_DIR/maintenance.log"
log(){ echo "[$(date '+%F %T')] [MAINT] $*" | tee -a "$MAINT_LOG"; }
NEED_RESTART=0; RETUNE=0; WAS_ACTIVE=0

log "=== maintenance start ==="

# 1) Fast-forward main only when the server checkout is clean.
if [ -d .git ]; then
  if git status --porcelain 2>/dev/null | grep -q .; then
    log "Working tree has local edits; skipping git update."
  else
    git fetch origin main >>"$MAINT_LOG" 2>&1 || true
    BEHIND="$(git rev-list HEAD..origin/main --count 2>/dev/null || echo 0)"
    case "$BEHIND" in ''|*[!0-9]*)BEHIND=0;; esac
    if [ "$BEHIND" -gt 0 ]; then
      log "Applying $BEHIND main commit(s)."
      if git pull --ff-only origin main >>"$MAINT_LOG" 2>&1; then NEED_RESTART=1; else log "Git update failed; keeping running revision."; fi
    fi
  fi
fi

# 2) Bounded cache/log cleanup. Never touch current media or kernel caches.
if [ -d "$CACHE_DIR" ]; then
  DELETED="$(find "$CACHE_DIR" -type f -name '*.json' -mtime +7 -delete -print 2>/dev/null | wc -l || echo 0)"
  log "Stale API cache removed: $DELETED file(s)."
fi
for f in "$LOG_DIR"/*.log; do
  [ -f "$f" ] || continue
  kb="$(du -k "$f" 2>/dev/null | awk '{print $1}' || echo 0)"; case "$kb" in ''|*[!0-9]*)kb=0;; esac
  if [ "$kb" -gt "${LOG_ROTATE_KB:-5120}" ]; then
    mv "$f" "$f.old" && gzip -f "$f.old" 2>/dev/null || true
    : > "$f"; log "Rotated $(basename "$f")."
  fi
done
find "$LOG_DIR" -type f -name '*.old.gz' -mtime +14 -delete 2>/dev/null || true

stale(){
  [ ! -f "$1" ] && return 0
  mt="$(stat -c%Y "$1" 2>/dev/null || stat -f%m "$1" 2>/dev/null || echo 0)"; case "$mt" in ''|*[!0-9]*)return 0;; esac
  [ "$(( $(date +%s)-mt ))" -gt "${2:-604800}" ]
}

# 3) Expensive benchmark must run on an idle box, only when stale (default 7d).
if stale "$RUNTIME/host.env" "${RETUNE_MAX_AGE_SEC:-604800}" || stale "$RUNTIME/net.env" "${RETUNE_MAX_AGE_SEC:-604800}"; then
  RETUNE=1
  if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet quran-live.service 2>/dev/null; then
    WAS_ACTIVE=1; log "Weekly retune due; stopping coordinated stream for a clean benchmark."
    systemctl --user stop quran-live.service 2>/dev/null || true
  elif [ -f "$RUNTIME/stream_active.flag" ]; then
    WAS_ACTIVE=1; touch "$RUNTIME/broadcast_stopped.flag"
    mpid="$(cat "$RUNTIME/stream_multi.pid" 2>/dev/null || true)"
    quran_stop_owned_pid "$mpid" master "$BASE_DIR/scripts/stream_multi.sh" || true
    rm -f "$RUNTIME/stream_multi.pid"
  fi
  "$BASE_DIR/scripts/stop_ui.sh" >/dev/null 2>&1 || true
  sleep 1
  "$BASE_DIR/scripts/benchmark_host.sh" --force >>"$MAINT_LOG" 2>&1 || log "Benchmark failed; previous safe behavior remains available."
  "$BASE_DIR/scripts/probe_egress.sh" --force >>"$MAINT_LOG" 2>&1 || log "Egress probe failed; network guard keeps prior/fallback behavior."
  rm -f "$RUNTIME/preflight.env" "$RUNTIME/governor.env" "$RUNTIME/governor.state"
  NEED_RESTART=1
fi

# 4) Restart only when code/benchmark changed, or if explicitly requested.
if [ "${MAINTENANCE_DAILY_RESTART:-0}" = "1" ]; then NEED_RESTART=1; fi
if [ "$NEED_RESTART" -eq 1 ] && [ ! -f "$RUNTIME/broadcast_stopped.flag" ]; then
  log "Reloading coordinated universal service with updated/tuned settings."
  "$BASE_DIR/scripts/control.sh" install-units >/dev/null 2>&1 || true
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user restart quran-live.service 2>/dev/null || true
  elif [ "$WAS_ACTIVE" -eq 1 ]; then
    nohup "$BASE_DIR/scripts/stream_multi.sh" >>"$LOG_DIR/stream.log" 2>&1 &
  fi
elif [ "$RETUNE" -eq 1 ] && [ "$WAS_ACTIVE" -eq 1 ]; then
  # Fallback retune sets a temporary stop flag. Resume only the stream that was
  # active before maintenance, and do not route through systemd-only control.sh.
  rm -f "$RUNTIME/broadcast_stopped.flag"
  if command -v systemctl >/dev/null 2>&1; then
    "$BASE_DIR/scripts/control.sh" start >/dev/null 2>&1 || true
  else
    nohup "$BASE_DIR/scripts/stream_multi.sh" >>"$LOG_DIR/stream.log" 2>&1 &
  fi
else
  log "No restart needed; healthy live session left untouched."
fi

log "=== maintenance complete ==="
