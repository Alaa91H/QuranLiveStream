#!/usr/bin/env bash
# Universal self-healing watchdog. Resource pressure is handled separately by
# resource_governor.sh; this script only repairs crashed/stalled components.
set -euo pipefail
exec 9>/tmp/quran-watchdog.lock
flock -n 9 || exit 0
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$BASE_DIR/runtime"; LOG_DIR="$BASE_DIR/logs"
mkdir -p "$RUNTIME" "$LOG_DIR"
LOG="$LOG_DIR/watchdog.log"
log(){ echo "[$(date '+%F %T')] [WATCHDOG] $*" | tee -a "$LOG"; }

[ -f "$RUNTIME/broadcast_stopped.flag" ] && exit 0
ACTIVE=0
[ -f "$RUNTIME/stream_active.flag" ] && ACTIVE=1
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet quran-live.service 2>/dev/null; then ACTIVE=1; fi
[ "$ACTIVE" -eq 1 ] || exit 0

PORT="${QURAN_WEB_PORT:-4177}"
WEB_OK=0
curl -s --max-time 8 --retry 1 "http://127.0.0.1:$PORT/api/health" 2>/dev/null | grep -q '"ok":true' && WEB_OK=1 || true
FF_OK=0
pgrep -f 'ffmpeg.*x11grab' >/dev/null 2>&1 && FF_OK=1 || true

if [ "$WEB_OK" -eq 0 ] || [ "$FF_OK" -eq 0 ]; then
  log "Recovery: web_ok=$WEB_OK ffmpeg_ok=$FF_OK — restarting universal broadcast service."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user restart quran-live.service || true
  else
    pkill -f 'stream_multi.sh' 2>/dev/null || true
    nohup "$BASE_DIR/scripts/stream_multi.sh" >>"$LOG_DIR/stream.log" 2>&1 &
  fi
fi

if command -v systemctl >/dev/null 2>&1 && ! systemctl --user is-active --quiet quran-live-governor.service 2>/dev/null; then
  systemctl --user start quran-live-governor.service 2>/dev/null || true
fi
