#!/usr/bin/env bash
# QuranLiveStream — read-only health probe for the coordinated universal stack.
# Recovery remains centralized in watchdog.sh; this command reports state and
# invokes the watchdog only when the live stack is demonstrably unhealthy.
set -uo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE_DIR"
[ -f .env ] && { set -a; source .env 2>/dev/null; set +a; } || true
RUNTIME="$BASE_DIR/runtime"; LOG_DIR="$BASE_DIR/logs"; mkdir -p "$RUNTIME" "$LOG_DIR"
LOG="$LOG_DIR/health.log"; PORT="${QURAN_WEB_PORT:-4177}"
log(){ echo "[$(date '+%F %T')] [HEALTH] $*" | tee -a "$LOG"; }

if [ -f "$RUNTIME/broadcast_stopped.flag" ]; then
  log "Broadcast intentionally stopped."
  exit 0
fi

ACTIVE=0
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet quran-live.service 2>/dev/null; then ACTIVE=1; fi
[ -f "$RUNTIME/stream_active.flag" ] && ACTIVE=1
if [ "$ACTIVE" -eq 0 ]; then
  log "Universal broadcast service is not active."
  exit 0
fi

FAIL=0
if curl -fsS --max-time 5 "http://127.0.0.1:$PORT/api/health" 2>/dev/null | grep -q '"ok":true'; then
  log "Web API healthy on port $PORT."
else
  log "FAIL web API unhealthy on port $PORT."
  FAIL=1
fi

EXPECTED=1
if [ -f "$RUNTIME/active_profile.env" ]; then
  unset ACTIVE_GROUPS 2>/dev/null || true
  source "$RUNTIME/active_profile.env" 2>/dev/null || true
  EXPECTED="${ACTIVE_GROUPS:-1}"
fi
case "$EXPECTED" in ''|*[!0-9]*)EXPECTED=1;; esac

NOW="$(date +%s)"; GOOD=0
for i in $(seq 0 $((EXPECTED-1))); do
  d="$RUNTIME/groups/g$i"; ok=1
  [ -s "$d/worker.env" ] || ok=0
  cp="$(cat "$d/chrome.pid" 2>/dev/null || true)"; xp="$(cat "$d/xvfb.pid" 2>/dev/null || true)"
  [ -n "$cp" ] && kill -0 "$cp" 2>/dev/null || ok=0
  [ -n "$xp" ] && kill -0 "$xp" 2>/dev/null || ok=0
  if [ -f "$d/ffmpeg.progress" ]; then
    mt="$(stat -c%Y "$d/ffmpeg.progress" 2>/dev/null || echo 0)"
    case "$mt" in ''|*[!0-9]*)mt=0;; esac
    [ $((NOW-mt)) -le 35 ] || ok=0
  else
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    GOOD=$((GOOD+1)); log "g$i healthy."
  else
    log "FAIL g$i incomplete or stale."
  fi
done
[ "$GOOD" -eq "$EXPECTED" ] || FAIL=1

AVAIL="$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo 0)"
case "$AVAIL" in ''|*[!0-9]*)AVAIL=0;; esac
if [ "$AVAIL" -gt 0 ] && [ "$AVAIL" -lt 100 ]; then log "WARN low available memory: ${AVAIL}MB."; fi

if [ "$FAIL" -ne 0 ]; then
  log "Stack unhealthy ($GOOD/$EXPECTED groups); delegating recovery to watchdog."
  "$BASE_DIR/scripts/watchdog.sh" >/dev/null 2>&1 || true
  exit 1
fi
log "Healthy: $GOOD/$EXPECTED group(s)."
exit 0
