#!/usr/bin/env bash
# ==============================================================================
# Quran Live Stream — Universal multi-platform broadcaster
# One render + one encode, fanned out to only the selected RTMP/RTMPS targets.
# Target selection: STREAM_TARGETS=youtube,tiktok,facebook,custom1
# Runtime override: scripts/control.sh start youtube,tiktok
# ==============================================================================
set -uo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE_DIR"

[ -f .env ] && { set -a; source .env 2>/dev/null; set +a; } || true
[ -f config/stream.conf ] && source config/stream.conf 2>/dev/null || true
source "$BASE_DIR/scripts/platforms.sh"
quran_targets_load

LOG_DIR="$BASE_DIR/logs"
RUNTIME="$BASE_DIR/runtime"
mkdir -p "$LOG_DIR" "$RUNTIME"
LOG="$LOG_DIR/stream.log"
DISPLAY_NUM="${QURAN_DISPLAY:-99}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STREAM] $*" | tee -a "$LOG"; }

to_kbit() {
  case "${1:-}" in
    *[kK]) echo "${1%[kK]}" ;;
    *[mM]) echo "$(( ${1%[mM]} * 1000 ))" ;;
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$1" ;;
  esac
}

BASE_PROFILE="${STREAM_PROFILE:-}"
GOVERNOR_PROFILE=""
GOVERNOR_FPS_CAP=""
if [ -f "$RUNTIME/governor.env" ] && [ "${RESOURCE_GOVERNOR:-1}" != "0" ]; then
  source "$RUNTIME/governor.env" 2>/dev/null || true
fi
if [ -n "${GOVERNOR_PROFILE:-}" ]; then
  STREAM_PROFILE="$GOVERNOR_PROFILE"
elif [ -z "$BASE_PROFILE" ] || [ "${BASE_PROFILE,,}" = "auto" ]; then
  unset STREAM_PROFILE
else
  STREAM_PROFILE="$BASE_PROFILE"
fi
export STREAM_PROFILE
source "$BASE_DIR/scripts/hardware_profile.sh"

TARGETS=()
URIS=()
while IFS= read -r target; do
  [ -n "$target" ] || continue
  if ! quran_target_valid_name "$target"; then
    log "ERROR: invalid target name '$target'. Allowed: letters, digits, . _ -"
    exit 1
  fi
  uri="$(quran_target_uri "$target" 2>/dev/null || true)"
  if [ -z "$uri" ]; then
    log "ERROR: selected target '$target' has no credentials. Configure $(quran_target_prefix "$target")_RTMP_TARGET or _RTMP_URL + _STREAM_KEY."
    exit 1
  fi
  case "$uri" in
    rtmp://*|rtmps://*) ;;
    *) log "ERROR: '$target' must use rtmp:// or rtmps://"; exit 1 ;;
  esac
  TARGETS+=("$target")
  URIS+=("$uri")
done < <(quran_targets_lines)

TARGET_COUNT=${#TARGETS[@]}
if [ "$TARGET_COUNT" -lt 1 ]; then
  log "ERROR: no selected streaming targets."
  exit 1
fi

LAYOUT="$(quran_resolve_layout)"
STREAM_LAYOUT_RESOLVED="$LAYOUT"
if [ "$LAYOUT" = "portrait" ]; then
  tmp="$STREAM_WIDTH"; STREAM_WIDTH="$STREAM_HEIGHT"; STREAM_HEIGHT="$tmp"
fi
if [ -n "${GOVERNOR_FPS_CAP:-}" ] && [[ "$GOVERNOR_FPS_CAP" =~ ^[0-9]+$ ]] && [ "$GOVERNOR_FPS_CAP" -gt 0 ] && [ "$STREAM_FPS" -gt "$GOVERNOR_FPS_CAP" ]; then
  STREAM_FPS="$GOVERNOR_FPS_CAP"
fi
export STREAM_LAYOUT_RESOLVED STREAM_WIDTH STREAM_HEIGHT STREAM_FPS

TARGET_SUMMARY=""
for t in "${TARGETS[@]}"; do
  desc="$(quran_target_redacted "$t")"
  TARGET_SUMMARY="${TARGET_SUMMARY}${TARGET_SUMMARY:+, }$desc"
done
log "Targets: $TARGET_SUMMARY"
log "Profile: $PROFILE_NAME | ${STREAM_WIDTH}x${STREAM_HEIGHT}@${STREAM_FPS}fps | layout=$LAYOUT | outputs=$TARGET_COUNT"

if ! "$BASE_DIR/scripts/preflight.sh" 2>&1 | tee -a "$LOG"; then
  log "Preflight BLOCKED: refusing to launch a broken broadcast."
  exit 1
fi
set -a
source "$RUNTIME/preflight.env" 2>/dev/null || true
set +a
EFF_AUDIO="${PREFLIGHT_AUDIO:-${AUDIO_MODE:-pulse}}"

VIDEO_KBIT="$(to_kbit "$VIDEO_BITRATE")"
for t in "${TARGETS[@]}"; do
  cap="$(quran_target_max_bitrate_kbit "$t")"
  if [ "$cap" -gt 0 ] && [ "$VIDEO_KBIT" -gt "$cap" ]; then
    log "Platform cap: $t limits video ${VIDEO_KBIT}k -> ${cap}k"
    VIDEO_KBIT="$cap"
  fi
done

if [ "${EGRESS_GUARD:-1}" = "1" ] && [ -f "$RUNTIME/net.env" ]; then
  set -a
  source "$RUNTIME/net.env" 2>/dev/null || true
  set +a
  if awk "BEGIN{exit !(${HOST_EGRESS_SAFE_MBPS:-0} > 0)}"; then
    SAFE_TOTAL_KBIT="$(awk "BEGIN{printf \"%.0f\", (${HOST_EGRESS_SAFE_MBPS:-0})*1000*0.90}")"
    SAFE_PER_TARGET="$((SAFE_TOTAL_KBIT / TARGET_COUNT))"
    AUDIO_KBIT="$(to_kbit "$AUDIO_BITRATE")"
    SAFE_VIDEO="$((SAFE_PER_TARGET - AUDIO_KBIT))"
    [ "$SAFE_VIDEO" -lt 350 ] && SAFE_VIDEO=350
    if [ "$VIDEO_KBIT" -gt "$SAFE_VIDEO" ]; then
      log "Egress guard: ${TARGET_COUNT} outputs share ${SAFE_TOTAL_KBIT}k safe uplink; video ${VIDEO_KBIT}k -> ${SAFE_VIDEO}k per output"
      VIDEO_KBIT="$SAFE_VIDEO"
    fi
  fi
fi
VIDEO_BITRATE="${VIDEO_KBIT}k"
MAX_BITRATE="$VIDEO_BITRATE"
export VIDEO_BITRATE MAX_BITRATE

HW_OK=0
VAAPI_PRE=()
VAAPI_VF="format=yuv420p"
VCODEC_ARGS=(-c:v "$VCODEC" -preset "$FFMPEG_PRESET" -tune "$FFMPEG_TUNE" -threads "$FFMPEG_THREADS")
if [ -n "${X264_PARAMS:-}" ]; then VCODEC_ARGS+=(-x264-params "$X264_PARAMS"); fi
if [ "${PREFLIGHT_HW_OK:-}" = "nvenc" ]; then
  HW_OK=1
  VCODEC_ARGS=(-c:v h264_nvenc -preset p4 -tune ll -rc cbr)
  log "Hardware encode: NVENC verified."
elif [ "${PREFLIGHT_HW_OK:-}" = "vaapi" ] && [ "${HW_ALLOW_EXPERIMENTAL:-0}" = "1" ]; then
  HW_OK=2
  VAAPI_PRE=(-vaapi_device /dev/dri/renderD128)
  VAAPI_VF="format=nv12,hwupload"
  VCODEC_ARGS=(-c:v h264_vaapi -bf 2)
  log "Hardware encode: VAAPI verified/opted-in."
fi

FPSMODE_ARGS=(-fps_mode cfr)
ffmpeg -hide_banner -h full 2>/dev/null | grep -q -- '-fps_mode' || FPSMODE_ARGS=(-vsync cfr)
AACENC_ARGS=(-c:a aac -aac_coder fast)
ffmpeg -hide_banner -h encoder=aac 2>/dev/null | grep -q 'aac_coder' || AACENC_ARGS=(-c:a aac)
TASKSET_PRE=()
if [ -n "${TASKSET_FFMPEG:-}" ] && command -v taskset >/dev/null 2>&1; then TASKSET_PRE=(taskset -c "$TASKSET_FFMPEG"); fi
GOP="$((STREAM_FPS * 2))"

escape_tee_uri() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//|/\\|}"
  printf '%s' "$s"
}
TEE_SPEC=""
for uri in "${URIS[@]}"; do
  escaped="$(escape_tee_uri "$uri")"
  slave="[f=flv:onfail=ignore]$escaped"
  TEE_SPEC="${TEE_SPEC}${TEE_SPEC:+|}${slave}"
done
TEE_EXTRA=()
if ffmpeg -hide_banner -h muxer=tee 2>/dev/null | grep -q 'use_fifo'; then
  TEE_EXTRA=(-use_fifo 1 -fifo_options "attempt_recovery=1:recover_any_error=1:recovery_wait_time=5:drop_pkts_on_overflow=1")
fi

log "Launching one shared UI + one encoder for $TARGET_COUNT selected destination(s)..."
"$BASE_DIR/scripts/broadcast_ui_dynamic.sh" >>"$LOG" 2>&1
rm -f "$RUNTIME/broadcast_stopped.flag"
touch "$RUNTIME/stream_active.flag"
{
  echo "ACTIVE_PROFILE=$PROFILE"
  echo "ACTIVE_WIDTH=$STREAM_WIDTH"
  echo "ACTIVE_HEIGHT=$STREAM_HEIGHT"
  echo "ACTIVE_FPS=$STREAM_FPS"
  echo "ACTIVE_TARGETS=$STREAM_TARGETS"
  echo "ACTIVE_TARGET_COUNT=$TARGET_COUNT"
  echo "ACTIVE_LAYOUT=$LAYOUT"
  echo "ACTIVE_TS=$(date +%s)"
} > "$RUNTIME/active_profile.env"
trap 'rm -f "$RUNTIME/stream_active.flag"; "$BASE_DIR/scripts/stop_ui.sh" >/dev/null 2>&1 || true' EXIT INT TERM

while true; do
  [ -f "$RUNTIME/broadcast_stopped.flag" ] && { log "Stop flag detected; exiting."; exit 0; }

  if [ "$EFF_AUDIO" = "file" ]; then
    "$BASE_DIR/scripts/build_audio_playlist.sh" >>"$LOG" 2>&1 || true
    if [ -s "$RUNTIME/audio_playlist.txt" ]; then
      AUDIO_INPUT_ARGS=(-re -stream_loop -1 -f concat -safe 0 -probesize 50k -analyzeduration 0 -thread_queue_size 64 -fflags +genpts -i "$RUNTIME/audio_playlist.txt")
    else
      log "Local audio playlist unavailable; using PulseAudio fallback."
      AUDIO_INPUT_ARGS=(-thread_queue_size 128 -f pulse -i quran_sink.monitor)
    fi
  else
    AUDIO_INPUT_ARGS=(-thread_queue_size 128 -f pulse -i quran_sink.monitor)
    if ! command -v pactl >/dev/null 2>&1 || ! pactl list short sources 2>/dev/null | grep -q quran_sink.monitor; then
      if [ -s "$RUNTIME/audio_playlist.txt" ]; then
        AUDIO_INPUT_ARGS=(-re -stream_loop -1 -f concat -safe 0 -probesize 50k -analyzeduration 0 -thread_queue_size 64 -fflags +genpts -i "$RUNTIME/audio_playlist.txt")
      else
        AUDIO_INPUT_ARGS=(-thread_queue_size 64 -f lavfi -i "anullsrc=r=${AUDIO_SAMPLERATE}:cl=stereo")
      fi
    fi
  fi

  log "Encoder start: ${STREAM_WIDTH}x${STREAM_HEIGHT}@${STREAM_FPS}, video=$VIDEO_BITRATE audio=$AUDIO_BITRATE, targets=$TARGET_COUNT"
  set +e
  "${TASKSET_PRE[@]}" ffmpeg -hide_banner -loglevel warning -nostdin -nostats -progress pipe:2 \
    "${VAAPI_PRE[@]}" \
    -f x11grab -framerate "$STREAM_FPS" -video_size "${STREAM_WIDTH}x${STREAM_HEIGHT}" -draw_mouse 0 \
    -thread_queue_size 64 -probesize 32k -analyzeduration 0 -i ":$DISPLAY_NUM.0" \
    "${AUDIO_INPUT_ARGS[@]}" \
    -map 0:v:0 -map 1:a:0 \
    -vf "$VAAPI_VF" \
    "${VCODEC_ARGS[@]}" \
    -b:v "$VIDEO_BITRATE" -maxrate "$MAX_BITRATE" -bufsize "$BUF_SIZE" \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -r "$STREAM_FPS" "${FPSMODE_ARGS[@]}" \
    "${AACENC_ARGS[@]}" -b:a "$AUDIO_BITRATE" -ar "$AUDIO_SAMPLERATE" -ac "$AUDIO_CHANNELS" \
    -af "aresample=${AUDIO_SAMPLERATE}:async=1:first_pts=0" \
    -flags +global_header -f tee "${TEE_EXTRA[@]}" "$TEE_SPEC" 2>&1 | tee -a "$LOG"
  EXIT_CODE=${PIPESTATUS[0]}
  set +e
  log "Encoder exited code=$EXIT_CODE; retrying in 4s."
  sleep 4
done
