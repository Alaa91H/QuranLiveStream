#!/usr/bin/env bash
# ==============================================================================
# Quran Live Stream — target-aware preflight
# Verifies the exact selected destinations and local render/audio prerequisites.
# No platform is mandatory: only STREAM_TARGETS are checked.
# ==============================================================================
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE_DIR"

[ -f .env ] && { set -a; source .env 2>/dev/null; set +a; } || true
[ -f config/stream.conf ] && source config/stream.conf 2>/dev/null || true
source "$BASE_DIR/scripts/platforms.sh"
quran_targets_load
if [ "${STREAM_PROFILE:-}" = "auto" ]; then unset STREAM_PROFILE; fi
source "$BASE_DIR/scripts/hardware_profile.sh" 2>/dev/null || true
eval "$("$BASE_DIR/scripts/detect_host.sh")" 2>/dev/null || true

LOG_DIR="$BASE_DIR/logs"
RUNTIME="$BASE_DIR/runtime"
mkdir -p "$LOG_DIR" "$RUNTIME"
LOG="$LOG_DIR/preflight.log"
OUT="$RUNTIME/preflight.env"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PREFLIGHT] $*" | tee -a "$LOG"; }
FAIL=0; WARN=0; AUDIO="pulse"; VIDEO="live"; RTMP_OK=1; TARGET_COUNT=0

command -v ffmpeg >/dev/null 2>&1 || { log "HARD FAIL: ffmpeg missing (run scripts/install_deps.sh)."; FAIL=1; }
command -v node >/dev/null 2>&1 || { log "HARD FAIL: node missing (run scripts/install_deps.sh)."; FAIL=1; }
BROWSER_HIT=""
for cand in "${CHROME_BIN:-}" google-chrome chromium-browser chromium; do
  [ -z "$cand" ] && continue
  if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then BROWSER_HIT="$cand"; break; fi
done
if [ -z "$BROWSER_HIT" ]; then
  log "HARD FAIL: no Chrome/Chromium binary (run scripts/install_browser.sh)."; FAIL=1
else
  log "Browser: $BROWSER_HIT ($("$BROWSER_HIT" --version 2>/dev/null || echo version-unknown))."
fi
command -v Xvfb >/dev/null 2>&1 || { log "HARD FAIL: Xvfb missing (run scripts/install_deps.sh)."; FAIL=1; }

STRICT="${RTMP_PREFLIGHT_STRICT:-0}"
while IFS= read -r target; do
  [ -n "$target" ] || continue
  TARGET_COUNT=$((TARGET_COUNT + 1))
  if ! quran_target_valid_name "$target"; then
    log "HARD FAIL: invalid target name '$target'."; FAIL=1; continue
  fi
  uri="$(quran_target_uri "$target" 2>/dev/null || true)"
  if [ -z "$uri" ]; then
    log "HARD FAIL: selected '$target' is missing $(quran_target_prefix "$target")_RTMP_TARGET or _RTMP_URL + _STREAM_KEY."; FAIL=1; continue
  fi
  case "$uri" in
    rtmp://*|rtmps://*) ;;
    *) log "HARD FAIL: '$target' URL must be RTMP/RTMPS."; FAIL=1; continue ;;
  esac
  read -r host port < <(quran_target_host_port "$uri")
  if [ -z "$host" ] || [ "${port:-0}" -le 0 ]; then
    log "HARD FAIL: cannot parse ingest endpoint for '$target'."; FAIL=1; continue
  fi
  if command -v timeout >/dev/null 2>&1; then
    if timeout 5 bash -c "(echo > /dev/tcp/$host/$port) 2>/dev/null"; then
      log "Target $(quran_target_redacted "$target"): TCP $port reachable."
    else
      RTMP_OK=0
      if [ "$STRICT" = "1" ]; then
        log "HARD FAIL: $(quran_target_redacted "$target") TCP $port unreachable."; FAIL=1
      else
        log "WARN: $(quran_target_redacted "$target") TCP $port probe failed; FFmpeg may still connect (set RTMP_PREFLIGHT_STRICT=1 to block)."; WARN=1
      fi
    fi
  else
    log "WARN: timeout/bash-tcp unavailable; skipping network probe for $(quran_target_redacted "$target")."; WARN=1
  fi
done < <(quran_targets_lines)
[ "$TARGET_COUNT" -gt 0 ] || { log "HARD FAIL: STREAM_TARGETS resolved to zero destinations."; FAIL=1; }

DISK_MB="$(df -kP . 2>/dev/null | awk 'NR==2{print int($4/1024)}' || true)"
case "$DISK_MB" in ''|*[!0-9]*) DISK_MB=0 ;; esac
[ "$DISK_MB" -lt 2048 ] && { log "WARN: only ${DISK_MB}MB free on filesystem (want 2GB+)."; WARN=1; }
AVAIL_MB="$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || true)"
case "$AVAIL_MB" in ''|*[!0-9]*) AVAIL_MB=9999 ;; esac
[ "$AVAIL_MB" -lt 100 ] && { log "WARN: only ${AVAIL_MB}MB RAM available."; WARN=1; }

if [ ! -f "$BASE_DIR/web/assets/fonts/fonts.css" ]; then
  log "Fonts missing, fetching inline..."
  if command -v node >/dev/null 2>&1 && node "$BASE_DIR/scripts/download_fonts.js" >>"$LOG" 2>&1; then
    log "Fonts ready."
  else
    log "WARN: font fetch failed; browser will use fallback fonts."; WARN=1
  fi
fi

MP3_COUNT="$(find "$BASE_DIR/web/assets/audio" -maxdepth 1 -name '*.mp3' -size +1000c 2>/dev/null | wc -l | tr -d ' ')"
case "$MP3_COUNT" in ''|*[!0-9]*) MP3_COUNT=0 ;; esac
REQUESTED_AUDIO="${AUDIO_MODE:-pulse}"
# Recitation timing is owned by the visible browser. Local MP3 files remain the
# browser's first choice, but FFmpeg must capture that same browser timeline via
# the Pulse monitor. A separate concat playlist can drift from the displayed
# ayah immediately after startup/restart, so it is never selected for broadcast.
if [ "$REQUESTED_AUDIO" = "file" ]; then
  WARN=1
  log "WARN: AUDIO_MODE=file resolved to synchronized browser/Pulse capture; $MP3_COUNT local mp3s remain preferred by the UI."
else
  log "Audio: synchronized browser/Pulse capture ($MP3_COUNT local mp3s cached)."
fi
AUDIO="pulse"
PULSE_READY=0
if command -v pactl >/dev/null 2>&1; then
  pactl info >/dev/null 2>&1 && PULSE_READY=1 || true
  if [ "$PULSE_READY" -eq 0 ] && command -v pulseaudio >/dev/null 2>&1; then
    pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true
    sleep 1
    pactl info >/dev/null 2>&1 && PULSE_READY=1 || true
  fi
fi
if [ "$PULSE_READY" -eq 1 ]; then
  log "Audio: PulseAudio daemon reachable."
else
  log "HARD FAIL: PulseAudio is required for synchronized recitation/display capture (run scripts/install_deps.sh)."
  FAIL=1
fi
VIDEO="live"

PORT="${QURAN_WEB_PORT:-4177}"
if (echo > /dev/tcp/127.0.0.1/$PORT) >/dev/null 2>&1; then
  if curl -s --max-time 5 "http://127.0.0.1:$PORT/api/health" 2>/dev/null | grep -q '"ok":true'; then
    log "Port $PORT: healthy Quran web server already running."
  else
    log "WARN: port $PORT is busy but unhealthy; launcher will attempt recovery."; WARN=1
  fi
else
  log "Port $PORT: free."
fi

HW_OK=""
if command -v ffmpeg >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  if [ "${HOST_HW_NVENC:-0}" = "1" ] || ffmpeg -hide_banner -encoders 2>/dev/null | grep -q ' h264_nvenc '; then
    if timeout 20 ffmpeg -hide_banner -loglevel error -nostdin -y \
      -f lavfi -i "nullsrc=s=320x240:r=10:d=2" -c:v h264_nvenc -preset p1 -b:v 500k -f null - >>"$LOG" 2>&1; then
      HW_OK="nvenc"; log "HW encoder verified: NVENC."
    fi
  fi
  if [ -z "$HW_OK" ] && ls /dev/dri/renderD* >/dev/null 2>&1; then
    if timeout 20 ffmpeg -hide_banner -loglevel error -nostdin -y -vaapi_device /dev/dri/renderD128 \
      -f lavfi -i "nullsrc=s=320x240:r=10:d=2" -vf 'format=nv12,hwupload' -c:v h264_vaapi -b:v 500k -f null - >>"$LOG" 2>&1; then
      HW_OK="vaapi"; log "HW encoder verified: VAAPI."
    fi
  fi
fi
[ -z "$HW_OK" ] && log "HW encode: none verified; using CPU x264."

VERDICT="READY"
[ "$WARN" = "1" ] && VERDICT="DEGRADED"
[ "$FAIL" = "1" ] && VERDICT="BLOCKED"
{
  echo "PREFLIGHT_AUDIO=$AUDIO"
  echo "PREFLIGHT_VIDEO=$VIDEO"
  echo "PREFLIGHT_RTMP_OK=$RTMP_OK"
  echo "PREFLIGHT_TARGET_COUNT=$TARGET_COUNT"
  echo "PREFLIGHT_TARGETS=$STREAM_TARGETS"
  echo "PREFLIGHT_HW_OK=$HW_OK"
  echo "PREFLIGHT_VERDICT=$VERDICT"
  echo "PREFLIGHT_MP3=$MP3_COUNT"
  echo "PREFLIGHT_TS=$(date +%s)"
} > "$OUT"

if [ "$FAIL" = "1" ]; then
  log "VERDICT: BLOCKED — fix hard failures above."
  exit 1
fi
log "VERDICT: $VERDICT — targets=$TARGET_COUNT audio=$AUDIO profile=${PROFILE:-?}."
exit 0
