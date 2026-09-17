#!/usr/bin/env bash
# ==============================================================================
# QuranLiveStream — one native encoder worker per planned output group
# No scale/crop/pad filters: Xvfb dimensions == browser viewport == encoder frame.
# ==============================================================================
set -uo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GROUP="${1:?group}"; LAYOUT="${2:?layout}"; PROFILE_REQ="${3:?profile}"; CODEC_REQ="${4:?codec}"; DISPLAY_NUM="${5:?display}"; TARGET_CSV="${6:?targets}"
cd "$BASE_DIR"
[ -f .env ] && { set -a; source .env 2>/dev/null; set +a; } || true
source "$BASE_DIR/scripts/platforms.sh"
STREAM_PROFILE="$PROFILE_REQ"; export STREAM_PROFILE
source "$BASE_DIR/scripts/hardware_profile.sh"
read -r STREAM_WIDTH STREAM_HEIGHT < <(quran_profile_dimensions "$PROFILE_REQ" "$LAYOUT")
RUNTIME="$BASE_DIR/runtime"; LOG_DIR="$BASE_DIR/logs"; GR="$RUNTIME/groups/$GROUP"
mkdir -p "$GR" "$LOG_DIR"
LOG="$LOG_DIR/stream_${GROUP}.log"; PROGRESS="$GR/ffmpeg.progress"
STOP_FLAG="$RUNTIME/broadcast_stopped.flag"

log(){ echo "[$(date '+%F %T')] [$GROUP] $*" | tee -a "$LOG"; }
to_kbit(){ case "${1:-}" in *[kK])echo "${1%[kK]}";; *[mM])echo "$(( ${1%[mM]}*1000 ))";; ''|*[!0-9]*)echo 0;; *)echo "$1";; esac; }
profile_quality_kbit(){
  local p="$1" fps="$2"
  case "$p" in
    nano) echo 600;; micro) echo 1000;; eco) [ "$fps" -ge 50 ] && echo 6000 || echo 4000;;
    balanced) [ "$fps" -ge 50 ] && echo 12000 || echo 8000;;
    high) [ "$fps" -ge 50 ] && echo 24000 || echo 15000;;
    ultra) [ "$fps" -ge 50 ] && echo 35000 || echo 30000;;
    extreme) [ "$fps" -ge 50 ] && echo 60000 || echo 45000;;
    *) echo 1000;;
  esac
}

# Target resolution/bitrate/fps intersection for this shared encoder.
IFS=',' read -ra TARGETS <<< "$TARGET_CSV"
TARGET_COUNT=${#TARGETS[@]}; [ "$TARGET_COUNT" -gt 0 ] || exit 1
FPS="$STREAM_FPS"
for t in "${TARGETS[@]}"; do
  cap="$(quran_target_max_fps "$t")"; [ "$cap" -lt "$FPS" ] && FPS="$cap"
done
if [ -f "$RUNTIME/governor.env" ]; then source "$RUNTIME/governor.env" 2>/dev/null || true; fi
if [[ "${GOVERNOR_FPS_CAP:-}" =~ ^[0-9]+$ ]] && [ "${GOVERNOR_FPS_CAP:-0}" -gt 0 ] && [ "$FPS" -gt "$GOVERNOR_FPS_CAP" ]; then FPS="$GOVERNOR_FPS_CAP"; fi
[ "$FPS" -lt 1 ] && FPS=1

VIDEO_KBIT="$(profile_quality_kbit "$PROFILE_REQ" "$FPS")"
for t in "${TARGETS[@]}"; do
  cap="$(quran_target_max_bitrate_kbit "$t")"
  [ "$cap" -gt 0 ] && [ "$cap" -lt "$VIDEO_KBIT" ] && VIDEO_KBIT="$cap"
done
# Egress is divided across every selected destination, not just this worker.
if [ "${EGRESS_GUARD:-1}" = "1" ] && [ -f "$RUNTIME/net.env" ]; then
  source "$RUNTIME/net.env" 2>/dev/null || true
  TOTAL_TARGETS="${STREAM_TOTAL_TARGETS:-$TARGET_COUNT}"
  [[ "$TOTAL_TARGETS" =~ ^[0-9]+$ ]] || TOTAL_TARGETS="$TARGET_COUNT"
  SAFE_TOTAL="$(awk "BEGIN{printf \"%.0f\", (${HOST_EGRESS_SAFE_MBPS:-0})*1000*0.88}")"
  if [ "$SAFE_TOTAL" -gt 0 ]; then
    AUDIO_K="$(to_kbit "$AUDIO_BITRATE")"; SAFE_EACH=$((SAFE_TOTAL/TOTAL_TARGETS)); SAFE_VIDEO=$((SAFE_EACH-AUDIO_K-64))
    [ "$SAFE_VIDEO" -lt 350 ] && SAFE_VIDEO=350
    [ "$VIDEO_KBIT" -gt "$SAFE_VIDEO" ] && VIDEO_KBIT="$SAFE_VIDEO"
  fi
fi
VIDEO_BITRATE="${VIDEO_KBIT}k"; MAX_BITRATE="$VIDEO_BITRATE"; BUF_SIZE="$((VIDEO_KBIT*2))k"

# Build tee destinations; one failed platform must not tear down healthy peers.
escape_tee_uri(){ local s="$1"; s="${s//\\/\\\\}"; s="${s//|/\\|}"; printf '%s' "$s"; }
TEE_SPEC=""; TARGET_SUMMARY=""
for t in "${TARGETS[@]}"; do
  uri="$(quran_target_uri "$t" 2>/dev/null || true)"; [ -n "$uri" ] || { log "Missing target URI: $t"; exit 1; }
  escaped="$(escape_tee_uri "$uri")"; TEE_SPEC="${TEE_SPEC}${TEE_SPEC:+|}[f=flv:onfail=ignore]$escaped"
  TARGET_SUMMARY="${TARGET_SUMMARY}${TARGET_SUMMARY:+,}$(quran_target_redacted "$t")"
done
TEE_EXTRA=(); if ffmpeg -hide_banner -h muxer=tee 2>/dev/null | grep -q 'use_fifo'; then TEE_EXTRA=(-use_fifo 1 -fifo_options "attempt_recovery=1:recover_any_error=1:recovery_wait_time=5:drop_pkts_on_overflow=1"); fi

# Preflight hardware verdict is shared across workers.
[ -f "$RUNTIME/preflight.env" ] && source "$RUNTIME/preflight.env" 2>/dev/null || true
VAAPI_PRE=(); VF="format=yuv420p"; VARGS=()
if [ "$CODEC_REQ" = "h264" ]; then
  if [ "${PREFLIGHT_HW_OK:-}" = "nvenc" ]; then
    VARGS=(-c:v h264_nvenc -preset p4 -tune hq -rc cbr -profile:v high)
  elif [ "${PREFLIGHT_HW_OK:-}" = "vaapi" ] && [ "${HW_ALLOW_EXPERIMENTAL:-0}" = "1" ]; then
    VAAPI_PRE=(-vaapi_device /dev/dri/renderD128); VF="format=nv12,hwupload"; VARGS=(-c:v h264_vaapi -bf 2)
  else
    VARGS=(-c:v libx264 -preset "$FFMPEG_PRESET" -tune zerolatency -threads "$FFMPEG_THREADS" -profile:v high)
    [ -n "${X264_PARAMS:-}" ] && VARGS+=(-x264-params "$X264_PARAMS")
  fi
elif [ "$CODEC_REQ" = "h265" ] || [ "$CODEC_REQ" = "hevc" ]; then
  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q ' hevc_nvenc ' && [ "${PREFLIGHT_HW_OK:-}" = "nvenc" ]; then VARGS=(-c:v hevc_nvenc -preset p4 -rc cbr)
  else VARGS=(-c:v libx265 -preset ultrafast -threads "$FFMPEG_THREADS"); fi
else
  log "Unsupported requested codec '$CODEC_REQ'; falling back to h264."
  VARGS=(-c:v libx264 -preset "$FFMPEG_PRESET" -tune zerolatency -threads "$FFMPEG_THREADS" -profile:v high)
fi

# Start exact native canvas for this worker.
"$BASE_DIR/scripts/broadcast_ui_group.sh" "$GROUP" "$LAYOUT" "$PROFILE_REQ" "$DISPLAY_NUM" >>"$LOG" 2>&1 || exit 1

AUDIO_INPUT=()
if [ "${AUDIO_MODE:-pulse}" = "file" ]; then
  "$BASE_DIR/scripts/build_audio_playlist.sh" >>"$LOG" 2>&1 || true
  if [ -s "$RUNTIME/audio_playlist.txt" ]; then AUDIO_INPUT=(-re -stream_loop -1 -f concat -safe 0 -probesize 50k -analyzeduration 0 -thread_queue_size 64 -fflags +genpts -i "$RUNTIME/audio_playlist.txt");
  else AUDIO_INPUT=(-thread_queue_size 64 -f lavfi -i "anullsrc=r=${AUDIO_SAMPLERATE}:cl=stereo"); fi
else
  AUDIO_INPUT=(-thread_queue_size 128 -f pulse -i quran_sink.monitor)
fi

FPSMODE=(-fps_mode cfr); ffmpeg -hide_banner -h full 2>/dev/null | grep -q -- '-fps_mode' || FPSMODE=(-vsync cfr)
GOP=$((FPS*2)); [ "$GOP" -lt 2 ] && GOP=2
printf 'GROUP=%s\nLAYOUT=%s\nPROFILE=%s\nWIDTH=%s\nHEIGHT=%s\nFPS=%s\nVIDEO_KBIT=%s\nTARGETS=%s\n' "$GROUP" "$LAYOUT" "$PROFILE_REQ" "$STREAM_WIDTH" "$STREAM_HEIGHT" "$FPS" "$VIDEO_KBIT" "$TARGET_CSV" > "$GR/worker.env"

while [ ! -f "$STOP_FLAG" ]; do
  rm -f "$PROGRESS"
  log "Native encode ${STREAM_WIDTH}x${STREAM_HEIGHT}@${FPS} ${VIDEO_BITRATE}, targets=$TARGET_SUMMARY"
  set +e
  ffmpeg -hide_banner -loglevel warning -nostdin \
    "${VAAPI_PRE[@]}" -f x11grab -framerate "$FPS" -video_size "${STREAM_WIDTH}x${STREAM_HEIGHT}" -draw_mouse 0 \
    -thread_queue_size 64 -probesize 32k -analyzeduration 0 -i ":$DISPLAY_NUM.0" \
    "${AUDIO_INPUT[@]}" -map 0:v:0 -map 1:a:0 -vf "$VF" \
    "${VARGS[@]}" -pix_fmt yuv420p -b:v "$VIDEO_BITRATE" -maxrate "$MAX_BITRATE" -bufsize "$BUF_SIZE" \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -r "$FPS" "${FPSMODE[@]}" \
    -c:a aac -b:a "$AUDIO_BITRATE" -ar "$AUDIO_SAMPLERATE" -ac "${AUDIO_CHANNELS:-2}" \
    -af "aresample=${AUDIO_SAMPLERATE}:async=1:first_pts=0" -flags +global_header \
    -progress "$PROGRESS" -stats_period 5 -f tee "${TEE_EXTRA[@]}" "$TEE_SPEC" >>"$LOG" 2>&1
  EC=$?; set -e
  [ -f "$STOP_FLAG" ] && break
  log "FFmpeg exited $EC; retry in 4s."; sleep 4
done
log "Worker stopped."
