#!/usr/bin/env bash
# Quran Live Stream — Universal Self-Healing Watchdog
set -Eeuo pipefail
exec 9>/tmp/quran-watchdog.lock
flock -n 9 || exit 0
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE_DIR"
[ -f .env ] && { set -a; source .env 2>/dev/null; set +a; } || true

LOG_DIR="$BASE_DIR/logs"; RUNTIME="$BASE_DIR/runtime"
mkdir -p "$LOG_DIR" "$RUNTIME"
WATCHDOG_LOG="$LOG_DIR/watchdog.log"
SERVICE="quran-live.service"
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WATCHDOG] $*" | tee -a "$WATCHDOG_LOG"; }

# Explicit stop means do nothing. This prevents cron from resurrecting a stream
# the operator intentionally stopped.
[ -f "$RUNTIME/broadcast_stopped.flag" ] && exit 0

SERVICE_ACTIVE=0
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet "$SERVICE" 2>/dev/null; then SERVICE_ACTIVE=1; fi

# If universal service is expected but FFmpeg vanished, restart the whole cgroup
# instead of launching a second browser/encoder stack.
if [ "$SERVICE_ACTIVE" -eq 1 ] && ! pgrep -f "ffmpeg.*x11grab" >/dev/null 2>&1; then
  log "FFmpeg missing while $SERVICE is active; restarting universal service."
  systemctl --user restart "$SERVICE" || true
  exit 0
fi

# Only inspect UI internals while the stream service is active.
[ "$SERVICE_ACTIVE" -eq 1 ] || exit 0
PORT="${QURAN_WEB_PORT:-4177}"
HEALTH_URL="http://127.0.0.1:$PORT/api/health"
if ! curl -s --max-time 10 --retry 1 --retry-delay 2 "$HEALTH_URL" | grep -q '"ok":true'; then
  log "Web health failed; restarting universal service for clean coordinated recovery."
  systemctl --user restart "$SERVICE" || true
  exit 0
fi

CHROME_PIDFILE="$RUNTIME/quran-chrome.pid"; XVFB_PIDFILE="$RUNTIME/quran-xvfb.pid"
if [ ! -f "$XVFB_PIDFILE" ] || ! kill -0 "$(cat "$XVFB_PIDFILE" 2>/dev/null)" 2>/dev/null; then
  log "Xvfb missing; restarting universal service."
  systemctl --user restart "$SERVICE" || true
  exit 0
fi
if [ ! -f "$CHROME_PIDFILE" ] || ! kill -0 "$(cat "$CHROME_PIDFILE" 2>/dev/null)" 2>/dev/null; then
  log "Chromium missing; restarting universal service."
  systemctl --user restart "$SERVICE" || true
  exit 0
fi

# Memory telemetry only: do NOT drop kernel caches. Linux page cache is reclaimable
# and force-dropping it can create I/O spikes that make realtime encoding worse.
AVAIL_RAM_MB="$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo 0)"
case "$AVAIL_RAM_MB" in ''|*[!0-9]*) AVAIL_RAM_MB=0;; esac
if [ "$AVAIL_RAM_MB" -gt 0 ] && [ "$AVAIL_RAM_MB" -lt 60 ]; then
  log "Low MemAvailable=${AVAIL_RAM_MB}MB; adaptive governor should downshift if sustained."
fi
