#!/usr/bin/env bash
# Quran Live Stream — Secondary Safety/Telemetry Monitor
# The realtime adaptive engine is the primary controller. This cron monitor only
# restarts the service if realtime speed remains critically low at the floor.
set -Eeuo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"; cd "$BASE_DIR"
[ -f .env ] && { set -a; source .env 2>/dev/null; set +a; } || true
LOG_DIR="$BASE_DIR/logs"; RUNTIME="$BASE_DIR/runtime"; mkdir -p "$LOG_DIR" "$RUNTIME"
MON_LOG="$LOG_DIR/speed_monitor.log"; STATE="$RUNTIME/speed_state"; SERVICE="quran-live.service"
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SPEED] $*" | tee -a "$MON_LOG"; }

# Disk guard: prune only disposable logs/cache.
disk_pct(){ local p; p="$(df -P "$BASE_DIR" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $5}')"; case "$p" in ''|*[!0-9]*) p=0;; esac; echo "$p"; }
if [ "$(disk_pct)" -ge 90 ]; then
  log "Disk >=90%: pruning rotated logs and stale cache."
  rm -f "$LOG_DIR"/*.old.gz 2>/dev/null || true
  find "$BASE_DIR/web/.cache" -type f -name '*.json' -mtime +3 -delete 2>/dev/null || true
fi

write_status(){
  local speed="$1" note="$2" cpu_line mem_avail rank
  cpu_line="$(cat "$RUNTIME/load.status" 2>/dev/null || echo unavailable)"
  mem_avail="$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo '?')"
  rank="$(cat "$RUNTIME/adaptive_rank" 2>/dev/null || echo auto)"
  printf '{"ts":%s,"speed":"%s","mem_avail_mb":"%s","rank":"%s","note":"%s","load":"%s"}\n' \
    "$(date +%s)" "$speed" "$mem_avail" "$rank" "$note" "${cpu_line//\"/}" > "$RUNTIME/status.json"
}

[ "${SPEED_MONITOR:-1}" = "0" ] && exit 0
if ! systemctl --user is-active --quiet "$SERVICE" 2>/dev/null; then write_status "" "service-inactive"; exit 0; fi
if ! pgrep -f "ffmpeg.*x11grab" >/dev/null 2>&1; then write_status "" "no-ffmpeg"; exit 0; fi

LAST_SPEED="$(grep '^speed=' "$RUNTIME/ffmpeg.progress" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d 'x' || true)"
if ! [[ "$LAST_SPEED" =~ ^[0-9]+([.][0-9]+)?$ ]]; then write_status "" "no-speed-data"; exit 0; fi
SPEED_MIN="${SPEED_MIN:-0.80}"; SPEED_HITS="${SPEED_HITS:-3}"
HITS="$(cut -d' ' -f1 "$STATE" 2>/dev/null || echo 0)"; case "$HITS" in ''|*[!0-9]*) HITS=0;; esac
SLOW="$(awk -v a="$LAST_SPEED" -v b="$SPEED_MIN" 'BEGIN{print(a<b?1:0)}')"
write_status "$LAST_SPEED" "ok"
if [ "$SLOW" = "1" ]; then
  HITS=$((HITS+1)); echo "$HITS $(date +%s)" > "$STATE"; log "LOW speed=${LAST_SPEED}x ($HITS/$SPEED_HITS)."
  RANK="$(cat "$RUNTIME/adaptive_rank" 2>/dev/null || echo 1)"; case "$RANK" in ''|*[!0-9]*) RANK=1;; esac
  if [ "$HITS" -ge "$SPEED_HITS" ] && [ "$RANK" -eq 0 ]; then
    log "Still below realtime at minimum profile; restarting universal service as last-resort recovery."
    echo "0 $(date +%s)" > "$STATE"
    systemctl --user restart "$SERVICE" 2>/dev/null || true
    "$BASE_DIR/scripts/notify_telegram.sh" "⚠️ QuranLive: encoder remained ${LAST_SPEED}x at minimum adaptive profile; universal service restarted." || true
  fi
else
  echo "0 $(date +%s)" > "$STATE"
fi
