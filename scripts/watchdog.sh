#!/usr/bin/env bash
# Universal self-healing watchdog. Resource pressure is handled by the governor;
# this script verifies the complete coordinated multi-layout stack.
set -euo pipefail
exec 9>/tmp/quran-watchdog.lock
flock -n 9 || exit 0
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$BASE_DIR/runtime"; LOG_DIR="$BASE_DIR/logs"
mkdir -p "$RUNTIME" "$LOG_DIR"
source "$BASE_DIR/scripts/process_guard.sh"
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

EXPECTED=1
if [ -f "$RUNTIME/active_profile.env" ]; then
  unset ACTIVE_GROUPS 2>/dev/null || true
  source "$RUNTIME/active_profile.env" 2>/dev/null || true
  EXPECTED="${ACTIVE_GROUPS:-1}"
fi
case "$EXPECTED" in ''|*[!0-9]*)EXPECTED=1;; esac

GROUP_OK=0; BROKEN=""; now="$(date +%s)"
for i in $(seq 0 $((EXPECTED-1))); do
  d="$RUNTIME/groups/g$i"; ok=1
  [ -f "$d/worker.env" ] || ok=0
  display="$(sed -n 's/^DISPLAY=//p' "$d/ui.env" 2>/dev/null | head -1 | tr -cd '0-9')"
  cp="$(cat "$d/chrome.pid" 2>/dev/null || true)"; xp="$(cat "$d/xvfb.pid" 2>/dev/null || true)"
  quran_owned_pid "$cp" browser "$d" || ok=0
  [ -n "$display" ] && quran_owned_pid "$xp" xvfb "$display" || ok=0

  # The worker owns FFmpeg explicitly and records its exact PID. Require both
  # ffmpeg identity and this group's private -progress path, not generic liveness.
  fp="$(cat "$d/ffmpeg.pid" 2>/dev/null || true)"
  quran_owned_pid "$fp" ffmpeg "$d/ffmpeg.progress" || ok=0

  # PID ownership alone is not proof of a healthy encoder: a blocked x11,
  # audio, network or muxer path can leave FFmpeg alive indefinitely. Require
  # its -progress heartbeat to remain fresh as well.
  if [ -f "$d/ffmpeg.progress" ]; then
    mt="$(stat -c%Y "$d/ffmpeg.progress" 2>/dev/null || echo 0)"
    case "$mt" in ''|*[!0-9]*) mt=0;; esac
    [ "$((now-mt))" -le 30 ] || ok=0
  else
    ok=0
  fi

  if [ "$ok" -eq 1 ]; then GROUP_OK=$((GROUP_OK+1)); else BROKEN="${BROKEN}${BROKEN:+,}g$i"; fi
done

if [ "$WEB_OK" -eq 0 ] || [ "$GROUP_OK" -lt "$EXPECTED" ]; then
  log "Recovery: web_ok=$WEB_OK groups=$GROUP_OK/$EXPECTED broken=${BROKEN:-none} — coordinated restart."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user restart quran-live.service || true
  else
    mpid="$(cat "$RUNTIME/stream_multi.pid" 2>/dev/null || true)"
    quran_stop_owned_pid "$mpid" master "$BASE_DIR/scripts/stream_multi.sh" || true
    rm -f "$RUNTIME/stream_multi.pid"
    nohup "$BASE_DIR/scripts/stream_multi.sh" >>"$LOG_DIR/stream.log" 2>&1 &
  fi
fi

if command -v systemctl >/dev/null 2>&1 && ! systemctl --user is-active --quiet quran-live-governor.service 2>/dev/null; then
  systemctl --user start quran-live-governor.service 2>/dev/null || true
fi
