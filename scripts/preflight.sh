#!/bin/bash
# ==============================================================================
# Quran Live Stream — Universal Preflight
# Verifies host inputs and ALL selected stream targets before the adaptive engine.
# Writes runtime/preflight.env and never starts large downloads in the hot path.
# ==============================================================================
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE_DIR"

[ -f .env ] && { set -a; source .env 2>/dev/null; set +a; } || true
source "$BASE_DIR/scripts/hardware_profile.sh" 2>/dev/null || true
eval "$("$BASE_DIR/scripts/detect_host.sh")" 2>/dev/null || true

LOG_DIR="$BASE_DIR/logs"
RUNTIME="$BASE_DIR/runtime"
mkdir -p "$LOG_DIR" "$RUNTIME"
LOG="$LOG_DIR/preflight.log"
OUT="$RUNTIME/preflight.env"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PREFLIGHT] $*" | tee -a "$LOG"; }
FAIL=0; WARN=0; AUDIO="pulse"; VIDEO="live"; RTMP_OK=0; TARGET_VALID=0; TARGET_REACHABLE=0

# --- 1. Binaries -------------------------------------------------------------
command -v ffmpeg >/dev/null 2>&1 || { log "HARD FAIL: ffmpeg missing (run scripts/install_deps.sh)."; FAIL=1; }
command -v node >/dev/null 2>&1 || { log "HARD FAIL: node missing (run scripts/install_deps.sh)."; FAIL=1; }
BROWSER_HIT=""
for cand in "${CHROME_BIN:-}" google-chrome chromium-browser chromium; do
  [ -z "$cand" ] && continue
  if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then BROWSER_HIT="$cand"; break; fi
done
if [ -z "$BROWSER_HIT" ]; then
  log "HARD FAIL: no chrome/chromium binary (run scripts/install_browser.sh)."; FAIL=1
else
  log "Browser: $BROWSER_HIT ($("$BROWSER_HIT" --version 2>/dev/null || echo version-unknown))."
fi
command -v Xvfb >/dev/null 2>&1 || { log "HARD FAIL: Xvfb missing (run scripts/install_deps.sh)."; FAIL=1; }

# --- 2. Selected platforms ---------------------------------------------------
STREAM_TARGETS="${STREAM_TARGETS:-youtube}"
target_value(){
  local slug="$1" suffix="$2" upper var
  upper="$(printf '%s' "$slug" | tr '[:lower:]-' '[:upper:]_')"
  var="${upper}_${suffix}"
  printf '%s' "${!var:-}"
}
default_url(){
  case "$1" in
    youtube) echo "rtmps://a.rtmps.youtube.com/live2" ;;
    facebook) echo "rtmps://live-api-s.facebook.com:443/rtmp" ;;
    twitch) echo "rtmp://live.twitch.tv/app" ;;
    *) echo "" ;;
  esac
}
requires_key(){ case "$1" in youtube|facebook|twitch|tiktok|kick) return 0;; *) return 1;; esac; }

IFS=',' read -ra TARGET_ARRAY <<< "$STREAM_TARGETS"
for raw in "${TARGET_ARRAY[@]}"; do
  slug="$(echo "$raw" | xargs | tr '[:upper:]' '[:lower:]')"
  [ -z "$slug" ] && continue
  url="$(target_value "$slug" RTMP_URL)"; key="$(target_value "$slug" STREAM_KEY)"
  [ -z "$url" ] && url="$(default_url "$slug")"
  if [ -z "$url" ]; then
    log "WARN: selected target '$slug' has no ${slug^^}_RTMP_URL; it will be skipped."; WARN=1; continue
  fi
  if requires_key "$slug" && [ -z "$key" ]; then
    log "WARN: selected target '$slug' has no stream key; it will be skipped."; WARN=1; continue
  fi
  TARGET_VALID=$((TARGET_VALID+1))

  scheme="${url%%://*}"
  hostport="${url#*://}"; hostport="${hostport%%/*}"
  host="${hostport%%:*}"
  if [[ "$hostport" == *:* ]]; then port="${hostport##*:}"; elif [ "$scheme" = "rtmps" ]; then port=443; else port=1935; fi
  if [ -z "$host" ]; then
    log "WARN: target '$slug' has malformed RTMP URL."; WARN=1; continue
  fi
  if command -v timeout >/dev/null 2>&1; then
    if timeout 5 bash -c "(echo > /dev/tcp/$host/$port) 2>/dev/null"; then
      TARGET_REACHABLE=$((TARGET_REACHABLE+1)); log "Target '$slug': $host:$port reachable."
    else
      log "WARN: target '$slug' cannot reach $host:$port right now."; WARN=1
    fi
  else
    TARGET_REACHABLE=$((TARGET_REACHABLE+1)); log "WARN: cannot TCP-test '$slug' (timeout unavailable); assuming reachable."; WARN=1
  fi
done

if [ "$TARGET_VALID" -eq 0 ]; then
  log "HARD FAIL: STREAM_TARGETS contains no usable destination."; FAIL=1
elif [ "$TARGET_REACHABLE" -eq 0 ]; then
  log "HARD FAIL: none of the configured destinations is reachable."; FAIL=1
else
  RTMP_OK=1
  log "Targets: $TARGET_REACHABLE/$TARGET_VALID currently reachable."
fi

# --- 3. Disk + memory floors -------------------------------------------------
DISK_MB="$(df -kP . 2>/dev/null | awk 'NR==2{print int($4/1024)}' || true)"
case "$DISK_MB" in ''|*[!0-9]*) DISK_MB=0 ;; esac
[ "$DISK_MB" -lt 2048 ] && { log "WARN: only ${DISK_MB}MB free on / (want 2GB+)."; WARN=1; }
AVAIL_MB="$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || true)"
case "$AVAIL_MB" in ''|*[!0-9]*) AVAIL_MB=9999 ;; esac
[ "$AVAIL_MB" -lt 100 ] && { log "WARN: only ${AVAIL_MB}MB RAM available."; WARN=1; }

# --- 4. Fonts ---------------------------------------------------------------
if [ ! -f "$BASE_DIR/web/assets/fonts/fonts.css" ]; then
  log "Fonts missing, fetching inline (small)..."
  if command -v node >/dev/null 2>&1 && node "$BASE_DIR/scripts/download_fonts.js" >>"$LOG" 2>&1; then
    log "Fonts ready."
  else
    log "WARN: font fetch failed, browser falls back to CDN/system fonts."; WARN=1
  fi
fi

# --- 5. Audio coverage -------------------------------------------------------
MP3_COUNT="$(find "$BASE_DIR/web/assets/audio" -maxdepth 1 -name '*.mp3' -size +1000c 2>/dev/null | wc -l | tr -d ' ')"
case "$MP3_COUNT" in ''|*[!0-9]*) MP3_COUNT=0 ;; esac
if [ "${AUDIO_MODE:-pulse}" = "file" ]; then
  if [ "$MP3_COUNT" -ge 2000 ]; then
    AUDIO="file"; log "Audio: file mode OK ($MP3_COUNT local mp3s)."
  else
    AUDIO="pulse"; log "WARN: file audio requested but only $MP3_COUNT mp3s -> pulse for this run."; WARN=1
  fi
else
  AUDIO="pulse"; log "Audio: pulse mode ($MP3_COUNT local mp3s cached)."
fi
if [ "$AUDIO" = "pulse" ] && ! command -v pactl >/dev/null 2>&1 && [ "$MP3_COUNT" -eq 0 ]; then
  log "HARD FAIL: pulse audio unavailable and no local audio exists."; FAIL=1
fi
VIDEO="live"; log "Video: live capture mode."

# --- 6. Local web port -------------------------------------------------------
PORT="${QURAN_WEB_PORT:-4177}"
if (echo > /dev/tcp/127.0.0.1/$PORT) >/dev/null 2>&1; then
  if curl -s --max-time 5 "http://127.0.0.1:$PORT/api/health" 2>/dev/null | grep -q '"ok":true'; then
    log "Port $PORT: healthy web server already answering."
  else
    log "WARN: port $PORT busy but unhealthy; launcher will recover it."; WARN=1
  fi
else
  log "Port $PORT: free."
fi

# --- 7. Hardware encoder smoke test -----------------------------------------
HW_OK=""
if command -v ffmpeg >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  if [ "${HOST_HW_NVENC:-0}" = "1" ] || ffmpeg -hide_banner -encoders 2>/dev/null | grep -q ' h264_nvenc '; then
    if timeout 20 ffmpeg -hide_banner -loglevel error -nostdin -y -f lavfi -i "nullsrc=s=320x240:r=10:d=2" -c:v h264_nvenc -preset p1 -b:v 500k -f null - >>"$LOG" 2>&1; then
      HW_OK="nvenc"; log "HW encoder verified: h264_nvenc."
    fi
  fi
  if [ -z "$HW_OK" ] && ls /dev/dri/renderD* >/dev/null 2>&1; then
    if timeout 20 ffmpeg -hide_banner -loglevel error -nostdin -y -vaapi_device /dev/dri/renderD128 -f lavfi -i "nullsrc=s=320x240:r=10:d=2" -vf 'format=nv12,hwupload' -c:v h264_vaapi -b:v 500k -f null - >>"$LOG" 2>&1; then
      HW_OK="vaapi"; log "HW encoder verified: h264_vaapi (opt-in)."
    fi
  fi
fi
[ -z "$HW_OK" ] && log "HW encode: none verified, CPU encode will be used."

VERDICT="READY"; [ "$WARN" = "1" ] && VERDICT="DEGRADED"; [ "$FAIL" = "1" ] && VERDICT="BLOCKED"
{
  echo "PREFLIGHT_AUDIO=$AUDIO"
  echo "PREFLIGHT_VIDEO=$VIDEO"
  echo "PREFLIGHT_RTMP_OK=$RTMP_OK"
  echo "PREFLIGHT_TARGET_VALID=$TARGET_VALID"
  echo "PREFLIGHT_TARGET_REACHABLE=$TARGET_REACHABLE"
  echo "PREFLIGHT_HW_OK=$HW_OK"
  echo "PREFLIGHT_VERDICT=$VERDICT"
  echo "PREFLIGHT_MP3=$MP3_COUNT"
  echo "PREFLIGHT_TS=$(date +%s)"
} > "$OUT"

if [ "$FAIL" = "1" ]; then log "VERDICT: HARD FAIL - not starting."; exit 1; fi
log "VERDICT: $VERDICT (audio=$AUDIO, reachable-targets=$TARGET_REACHABLE)."
exit 0
