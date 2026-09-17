#!/usr/bin/env bash
# Quran Live Stream — Universal Adaptive Multi-Platform Engine
# One render + one encode -> N selected RTMP/RTMPS destinations via FFmpeg tee.
# Dynamically downshifts/upshifts profile to keep sustained host load below limits.
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE_DIR"
[ -f .env ] && { set -a; source .env; set +a; }
[ -f config/stream.conf ] && source config/stream.conf

LOG_DIR="$BASE_DIR/logs"
RUNTIME="$BASE_DIR/runtime"
mkdir -p "$LOG_DIR" "$RUNTIME"
LOG="$LOG_DIR/stream_universal.log"
PROGRESS="$RUNTIME/ffmpeg.progress"
RANK_FILE="$RUNTIME/adaptive_rank"
STOP_FLAG="$RUNTIME/broadcast_stopped.flag"
DISPLAY_NUM="${QURAN_DISPLAY:-99}"

# ---------- policy -----------------------------------------------------------
STREAM_TARGETS="${STREAM_TARGETS:-youtube}"
ADAPTIVE_ENABLE="${ADAPTIVE_ENABLE:-1}"
CPU_TARGET="${CPU_TARGET:-80}"          # preferred sustained ceiling
CPU_HARD_LIMIT="${CPU_HARD_LIMIT:-90}" # downshift aggressively at/above this
RAM_TARGET="${RAM_TARGET:-82}"
RAM_HARD_LIMIT="${RAM_HARD_LIMIT:-90}"
ADAPTIVE_SAMPLE_SEC="${ADAPTIVE_SAMPLE_SEC:-5}"
ADAPTIVE_OVERLOAD_SAMPLES="${ADAPTIVE_OVERLOAD_SAMPLES:-3}"
ADAPTIVE_UNDERLOAD_SAMPLES="${ADAPTIVE_UNDERLOAD_SAMPLES:-24}"
ADAPTIVE_COOLDOWN_SEC="${ADAPTIVE_COOLDOWN_SEC:-180}"
ADAPTIVE_UPSHIFT="${ADAPTIVE_UPSHIFT:-1}"
FFMPEG_MIN_SPEED="${FFMPEG_MIN_SPEED:-0.97}"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

profile_rank(){
  case "$1" in nano) echo 0;; micro) echo 1;; eco) echo 2;; balanced) echo 3;; high) echo 4;; ultra) echo 5;; extreme) echo 6;; *) echo 1;; esac
}
rank_profile(){
  case "$1" in 0) echo nano;; 1) echo micro;; 2) echo eco;; 3) echo balanced;; 4) echo high;; 5) echo ultra;; *) echo extreme;; esac
}

# Detect the host/benchmark-selected maximum safe profile once.
unset STREAM_PROFILE || true
source "$BASE_DIR/scripts/hardware_profile.sh"
BASE_PROFILE="$PROFILE"
BASE_RANK="$(profile_rank "$BASE_PROFILE")"
CURRENT_RANK="$BASE_RANK"
if [ -s "$RANK_FILE" ]; then
  SAVED="$(cat "$RANK_FILE" 2>/dev/null || echo "$BASE_RANK")"
  [[ "$SAVED" =~ ^[0-6]$ ]] && CURRENT_RANK="$SAVED"
  [ "$CURRENT_RANK" -gt "$BASE_RANK" ] && CURRENT_RANK="$BASE_RANK"
fi

load_profile(){
  local p; p="$(rank_profile "$1")"
  STREAM_PROFILE="$p"
  export STREAM_PROFILE
  # shellcheck disable=SC1091
  source "$BASE_DIR/scripts/hardware_profile.sh"
}
load_profile "$CURRENT_RANK"

# ---------- destinations -----------------------------------------------------
# STREAM_TARGETS is comma-separated. Any slug works if SLUG_RTMP_URL and
# SLUG_STREAM_KEY exist. Built-in examples: youtube,tiktok,facebook,twitch,kick.
# A key may be empty when the URL already contains the complete publish path.
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

build_outputs(){
  local raw slug url key full spec="" count=0
  IFS=',' read -ra TARGET_ARRAY <<< "$STREAM_TARGETS"
  for raw in "${TARGET_ARRAY[@]}"; do
    slug="$(echo "$raw" | xargs | tr '[:upper:]' '[:lower:]')"
    [ -z "$slug" ] && continue
    url="$(target_value "$slug" RTMP_URL)"
    key="$(target_value "$slug" STREAM_KEY)"
    [ -z "$url" ] && url="$(default_url "$slug")"
    if [ -z "$url" ]; then
      log "TARGET SKIP: '$slug' has no ${slug^^}_RTMP_URL."
      continue
    fi
    if [ -n "$key" ]; then full="${url%/}/$key"; else full="$url"; fi
    # tee uses | as separator; reject malformed destination instead of corrupting all outputs.
    if [[ "$full" == *'|'* ]]; then
      log "TARGET SKIP: '$slug' URL contains unsupported | character."
      continue
    fi
    [ -n "$spec" ] && spec+="|"
    spec+="[f=flv:onfail=ignore]$full"
    count=$((count+1))
    log "TARGET ENABLED: $slug"
  done
  if [ "$count" -eq 0 ]; then
    log "ERROR: no valid stream targets. Set STREAM_TARGETS and matching *_RTMP_URL/*_STREAM_KEY."
    return 1
  fi
  TEE_OUTPUT="$spec"
  TARGET_COUNT="$count"
  export TEE_OUTPUT TARGET_COUNT
}
build_outputs

# ---------- host telemetry ---------------------------------------------------
read_cpu(){
  awk '/^cpu /{idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; print total, idle; exit}' /proc/stat
}
read_ram_pct(){
  awk '/MemTotal:/{t=$2}/MemAvailable:/{a=$2} END{if(t>0) printf "%.0f", (t-a)*100/t; else print 0}' /proc/meminfo
}
read_speed(){
  local s
  s="$(grep '^speed=' "$PROGRESS" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d 'x' || true)"
  [[ "$s" =~ ^[0-9]+([.][0-9]+)?$ ]] && echo "$s" || echo "1.00"
}
float_lt(){ awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }

adaptive_monitor(){
  local ffpid="$1" prev_total prev_idle total idle dt di cpu ram speed
  local over=0 under=0 last_change now new_rank
  read -r prev_total prev_idle < <(read_cpu)
  last_change="$(date +%s)"
  while kill -0 "$ffpid" 2>/dev/null; do
    sleep "$ADAPTIVE_SAMPLE_SEC"
    read -r total idle < <(read_cpu)
    dt=$((total-prev_total)); di=$((idle-prev_idle)); prev_total=$total; prev_idle=$idle
    if [ "$dt" -gt 0 ]; then cpu=$(( (100*(dt-di))/dt )); else cpu=0; fi
    ram="$(read_ram_pct)"
    speed="$(read_speed)"
    printf '%s CPU=%s%% RAM=%s%% speed=%sx profile=%s targets=%s\n' "$(date '+%F %T')" "$cpu" "$ram" "$speed" "$PROFILE" "$TARGET_COUNT" > "$RUNTIME/load.status"

    if [ "$cpu" -ge "$CPU_HARD_LIMIT" ] || [ "$ram" -ge "$RAM_HARD_LIMIT" ] || float_lt "$speed" "$FFMPEG_MIN_SPEED"; then
      over=$((over+1)); under=0
    elif [ "$cpu" -gt "$CPU_TARGET" ] || [ "$ram" -gt "$RAM_TARGET" ]; then
      over=$((over+1)); under=0
    elif [ "$cpu" -le $((CPU_TARGET-15)) ] && [ "$ram" -le $((RAM_TARGET-10)) ] && ! float_lt "$speed" "1.00"; then
      under=$((under+1)); over=0
    else
      over=0; under=0
    fi

    now="$(date +%s)"
    if [ "$ADAPTIVE_ENABLE" = "1" ] && [ "$over" -ge "$ADAPTIVE_OVERLOAD_SAMPLES" ] && [ "$CURRENT_RANK" -gt 0 ] && [ $((now-last_change)) -ge 30 ]; then
      new_rank=$((CURRENT_RANK-1))
      echo "$new_rank" > "$RANK_FILE"
      log "ADAPT DOWN: sustained load CPU=${cpu}% RAM=${ram}% speed=${speed}x -> $(rank_profile "$new_rank")"
      kill -TERM "$ffpid" 2>/dev/null || true
      return 0
    fi
    if [ "$ADAPTIVE_ENABLE" = "1" ] && [ "$ADAPTIVE_UPSHIFT" = "1" ] && [ "$under" -ge "$ADAPTIVE_UNDERLOAD_SAMPLES" ] && [ "$CURRENT_RANK" -lt "$BASE_RANK" ] && [ $((now-last_change)) -ge "$ADAPTIVE_COOLDOWN_SEC" ]; then
      new_rank=$((CURRENT_RANK+1))
      [ "$new_rank" -gt "$BASE_RANK" ] && new_rank="$BASE_RANK"
      echo "$new_rank" > "$RANK_FILE"
      log "ADAPT UP: long stable headroom CPU=${cpu}% RAM=${ram}% speed=${speed}x -> $(rank_profile "$new_rank")"
      kill -TERM "$ffpid" 2>/dev/null || true
      return 0
    fi
  done
}

# ---------- preflight + UI ----------------------------------------------------
if ! "$BASE_DIR/scripts/preflight.sh" >>"$LOG" 2>&1; then
  log "ERROR: preflight failed; refusing to start."
  exit 1
fi
"$BASE_DIR/scripts/broadcast_ui.sh" >>"$LOG" 2>&1
trap 'touch "$STOP_FLAG"; "$BASE_DIR/scripts/stop_ui.sh" >/dev/null 2>&1 || true' EXIT INT TERM
rm -f "$STOP_FLAG"

# ---------- encode loop ------------------------------------------------------
while [ ! -f "$STOP_FLAG" ]; do
  CURRENT_RANK="$(cat "$RANK_FILE" 2>/dev/null || echo "$BASE_RANK")"
  [[ "$CURRENT_RANK" =~ ^[0-6]$ ]] || CURRENT_RANK="$BASE_RANK"
  [ "$CURRENT_RANK" -gt "$BASE_RANK" ] && CURRENT_RANK="$BASE_RANK"
  load_profile "$CURRENT_RANK"
  build_outputs
  rm -f "$PROGRESS"

  # File audio is preferred on tiny hosts; otherwise use the browser sink.
  AUDIO_INPUT=()
  if [ "${AUDIO_MODE:-pulse}" = "file" ]; then
    "$BASE_DIR/scripts/build_audio_playlist.sh" >>"$LOG" 2>&1 || true
    if [ -s "$RUNTIME/audio_playlist.txt" ]; then
      AUDIO_INPUT=(-re -stream_loop -1 -f concat -safe 0 -probesize 50k -analyzeduration 0 -thread_queue_size 64 -fflags +genpts -i "$RUNTIME/audio_playlist.txt")
    else
      AUDIO_INPUT=(-thread_queue_size 64 -f pulse -i quran_sink.monitor)
    fi
  else
    AUDIO_INPUT=(-thread_queue_size 128 -f pulse -i quran_sink.monitor)
  fi

  VARGS=(-c:v "$VCODEC" -preset "$FFMPEG_PRESET" -tune "$FFMPEG_TUNE" -threads "$FFMPEG_THREADS")
  [ -n "${X264_PARAMS:-}" ] && [ "$VCODEC" = "libx264" ] && VARGS+=(-x264-params "$X264_PARAMS")
  GOP=$((STREAM_FPS*2))

  log "START: profile=$PROFILE ${STREAM_WIDTH}x${STREAM_HEIGHT}@${STREAM_FPS} targets=$TARGET_COUNT cpu-target=${CPU_TARGET}% hard=${CPU_HARD_LIMIT}%"
  ffmpeg -hide_banner -loglevel warning -nostdin \
    -f x11grab -framerate "$STREAM_FPS" -video_size "${STREAM_WIDTH}x${STREAM_HEIGHT}" -draw_mouse 0 -thread_queue_size 64 -probesize 32k -analyzeduration 0 -i ":$DISPLAY_NUM.0" \
    "${AUDIO_INPUT[@]}" \
    -map 0:v:0 -map 1:a:0 -vf format=yuv420p \
    "${VARGS[@]}" -b:v "$VIDEO_BITRATE" -maxrate "$MAX_BITRATE" -bufsize "$BUF_SIZE" \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -r "$STREAM_FPS" \
    -c:a aac -b:a "$AUDIO_BITRATE" -ar "$AUDIO_SAMPLERATE" -ac "${AUDIO_CHANNELS:-2}" \
    -af "aresample=${AUDIO_SAMPLERATE}:async=1:first_pts=0" \
    -progress "$PROGRESS" -stats_period "$ADAPTIVE_SAMPLE_SEC" \
    -f tee "$TEE_OUTPUT" >>"$LOG" 2>&1 &
  FFPID=$!

  adaptive_monitor "$FFPID" & MONPID=$!
  wait "$FFPID" || true
  kill "$MONPID" 2>/dev/null || true
  wait "$MONPID" 2>/dev/null || true
  [ -f "$STOP_FLAG" ] && break
  log "Encoder stopped/reconfigured; restarting in 3s..."
  sleep 3
done

log "Universal stream stopped."
