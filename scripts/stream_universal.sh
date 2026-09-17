#!/usr/bin/env bash
# Quran Live Stream — Universal Adaptive Multi-Platform Engine
# One render + one encode -> N selected RTMP/RTMPS destinations via FFmpeg tee.
# Dynamically downshifts/upshifts the whole render+encode stack to keep sustained
# host load below configured limits.
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE_DIR"
[ -f .env ] && { set -a; source .env; set +a; }
[ -f config/stream.conf ] && source config/stream.conf

LOG_DIR="$BASE_DIR/logs"; RUNTIME="$BASE_DIR/runtime"
mkdir -p "$LOG_DIR" "$RUNTIME"
LOG="$LOG_DIR/stream_universal.log"
PROGRESS="$RUNTIME/ffmpeg.progress"
RANK_FILE="$RUNTIME/adaptive_rank"
STOP_FLAG="$RUNTIME/broadcast_stopped.flag"
UI_SIG_FILE="$RUNTIME/ui_profile.sig"
DISPLAY_NUM="${QURAN_DISPLAY:-99}"

STREAM_TARGETS="${STREAM_TARGETS:-youtube}"
ADAPTIVE_ENABLE="${ADAPTIVE_ENABLE:-1}"
CPU_TARGET="${CPU_TARGET:-80}"
CPU_HARD_LIMIT="${CPU_HARD_LIMIT:-90}"
RAM_TARGET="${RAM_TARGET:-82}"
RAM_HARD_LIMIT="${RAM_HARD_LIMIT:-90}"
ADAPTIVE_SAMPLE_SEC="${ADAPTIVE_SAMPLE_SEC:-5}"
ADAPTIVE_OVERLOAD_SAMPLES="${ADAPTIVE_OVERLOAD_SAMPLES:-3}"
ADAPTIVE_UNDERLOAD_SAMPLES="${ADAPTIVE_UNDERLOAD_SAMPLES:-24}"
ADAPTIVE_COOLDOWN_SEC="${ADAPTIVE_COOLDOWN_SEC:-180}"
ADAPTIVE_UPSHIFT="${ADAPTIVE_UPSHIFT:-1}"
FFMPEG_MIN_SPEED="${FFMPEG_MIN_SPEED:-0.97}"
EGRESS_GUARD="${EGRESS_GUARD:-1}"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
profile_rank(){ case "$1" in nano) echo 0;; micro) echo 1;; eco) echo 2;; balanced) echo 3;; high) echo 4;; ultra) echo 5;; extreme) echo 6;; *) echo 1;; esac; }
rank_profile(){ case "$1" in 0) echo nano;; 1) echo micro;; 2) echo eco;; 3) echo balanced;; 4) echo high;; 5) echo ultra;; *) echo extreme;; esac; }

# STREAM_PROFILE acts only as a maximum ceiling in universal mode. It cannot
# force a weak server above the benchmark/hardware-selected safe profile.
REQUESTED_MAX_PROFILE="${STREAM_PROFILE:-}"
unset STREAM_PROFILE || true
source "$BASE_DIR/scripts/hardware_profile.sh"
BASE_PROFILE="$PROFILE"; BASE_RANK="$(profile_rank "$BASE_PROFILE")"
if [ -n "$REQUESTED_MAX_PROFILE" ]; then
  REQUESTED_RANK="$(profile_rank "$REQUESTED_MAX_PROFILE")"
  if [ "$REQUESTED_RANK" -lt "$BASE_RANK" ]; then BASE_RANK="$REQUESTED_RANK"; BASE_PROFILE="$(rank_profile "$BASE_RANK")"; fi
fi
CURRENT_RANK="$BASE_RANK"
if [ -s "$RANK_FILE" ]; then
  SAVED="$(cat "$RANK_FILE" 2>/dev/null || echo "$BASE_RANK")"
  [[ "$SAVED" =~ ^[0-6]$ ]] && CURRENT_RANK="$SAVED"
  [ "$CURRENT_RANK" -gt "$BASE_RANK" ] && CURRENT_RANK="$BASE_RANK"
fi

load_profile(){
  local p; p="$(rank_profile "$1")"
  STREAM_PROFILE="$p"; export STREAM_PROFILE
  source "$BASE_DIR/scripts/hardware_profile.sh"
}
load_profile "$CURRENT_RANK"

# ---------- destinations -----------------------------------------------------
target_value(){
  local slug="$1" suffix="$2" upper var
  upper="$(printf '%s' "$slug" | tr '[:lower:]-' '[:upper:]_')"; var="${upper}_${suffix}"
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
build_outputs(){
  local raw slug url key full spec="" count=0
  IFS=',' read -ra TARGET_ARRAY <<< "$STREAM_TARGETS"
  for raw in "${TARGET_ARRAY[@]}"; do
    slug="$(echo "$raw" | xargs | tr '[:upper:]' '[:lower:]')"; [ -z "$slug" ] && continue
    url="$(target_value "$slug" RTMP_URL)"; key="$(target_value "$slug" STREAM_KEY)"; [ -z "$url" ] && url="$(default_url "$slug")"
    if [ -z "$url" ]; then log "TARGET SKIP: '$slug' has no RTMP URL."; continue; fi
    if requires_key "$slug" && [ -z "$key" ]; then log "TARGET SKIP: '$slug' has no stream key."; continue; fi
    if [ -n "$key" ]; then full="${url%/}/$key"; else full="$url"; fi
    if [[ "$full" == *'|'* ]]; then log "TARGET SKIP: '$slug' URL contains unsupported | character."; continue; fi
    [ -n "$spec" ] && spec+="|"; spec+="[f=flv:onfail=ignore]$full"; count=$((count+1)); log "TARGET ENABLED: $slug"
  done
  if [ "$count" -eq 0 ]; then log "ERROR: no valid stream targets."; return 1; fi
  TEE_OUTPUT="$spec"; TARGET_COUNT="$count"; export TEE_OUTPUT TARGET_COUNT
}
build_outputs

# ---------- bandwidth governor ----------------------------------------------
to_kbit(){ case "$1" in *[kK]) echo "${1%[kK]}";; *[mM]) echo "$((${1%[mM]}*1000))";; ''|*[!0-9]*) echo 0;; *) echo "$1";; esac; }
apply_egress_guard(){
  [ "$EGRESS_GUARD" = "1" ] || return 0; [ -f "$RUNTIME/net.env" ] || return 0
  set -a; source "$RUNTIME/net.env" 2>/dev/null || true; set +a
  local safe_total safe_each audio now_video new_video
  safe_total="$(awk "BEGIN{printf \"%.0f\", (${HOST_EGRESS_SAFE_MBPS:-0})*1000*0.88}")"; [ "$safe_total" -gt 0 ] || return 0
  safe_each=$((safe_total/TARGET_COUNT)); audio="$(to_kbit "$AUDIO_BITRATE")"; now_video="$(to_kbit "$VIDEO_BITRATE")"; new_video=$((safe_each-audio-64))
  [ "$new_video" -lt 350 ] && new_video=350
  if [ "$now_video" -gt "$new_video" ]; then
    log "EGRESS CLAMP: ${TARGET_COUNT} outputs share ${safe_total}kbit safe uplink; video ${VIDEO_BITRATE} -> ${new_video}k each."
    VIDEO_BITRATE="${new_video}k"; MAX_BITRATE="$VIDEO_BITRATE"; BUF_SIZE="$((new_video*2))k"
  fi
}

# ---------- host telemetry ---------------------------------------------------
read_cpu(){ awk '/^cpu /{idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; print total, idle; exit}' /proc/stat; }
read_ram_pct(){ awk '/MemTotal:/{t=$2}/MemAvailable:/{a=$2} END{if(t>0) printf "%.0f", (t-a)*100/t; else print 0}' /proc/meminfo; }
read_speed(){ local s; s="$(grep '^speed=' "$PROGRESS" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d 'x' || true)"; [[ "$s" =~ ^[0-9]+([.][0-9]+)?$ ]] && echo "$s" || echo "1.00"; }
float_lt(){ awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }
adaptive_monitor(){
  local ffpid="$1" prev_total prev_idle total idle dt di cpu ram speed hard
  local over=0 under=0 last_change now new_rank
  read -r prev_total prev_idle < <(read_cpu); last_change="$(date +%s)"
  while kill -0 "$ffpid" 2>/dev/null; do
    sleep "$ADAPTIVE_SAMPLE_SEC"
    read -r total idle < <(read_cpu); dt=$((total-prev_total)); di=$((idle-prev_idle)); prev_total=$total; prev_idle=$idle
    if [ "$dt" -gt 0 ]; then cpu=$((100*(dt-di)/dt)); else cpu=0; fi
    ram="$(read_ram_pct)"; speed="$(read_speed)"; hard=0
    printf '%s CPU=%s%% RAM=%s%% speed=%sx profile=%s targets=%s\n' "$(date '+%F %T')" "$cpu" "$ram" "$speed" "$PROFILE" "$TARGET_COUNT" > "$RUNTIME/load.status"

    if [ "$cpu" -ge "$CPU_HARD_LIMIT" ] || [ "$ram" -ge "$RAM_HARD_LIMIT" ]; then hard=1; over=$((over+1)); under=0
    elif float_lt "$speed" "$FFMPEG_MIN_SPEED" || [ "$cpu" -gt "$CPU_TARGET" ] || [ "$ram" -gt "$RAM_TARGET" ]; then over=$((over+1)); under=0
    elif [ "$cpu" -le $((CPU_TARGET-15)) ] && [ "$ram" -le $((RAM_TARGET-10)) ] && ! float_lt "$speed" "1.00"; then under=$((under+1)); over=0
    else over=0; under=0; fi

    now="$(date +%s)"
    # Hard CPU/RAM limit gets a fast reaction after one sample; ordinary pressure
    # requires several samples so transient spikes do not flap the broadcast.
    if [ "$ADAPTIVE_ENABLE" = "1" ] && [ "$CURRENT_RANK" -gt 0 ] && { [ "$hard" = "1" ] || { [ "$over" -ge "$ADAPTIVE_OVERLOAD_SAMPLES" ] && [ $((now-last_change)) -ge 30 ]; }; }; then
      new_rank=$((CURRENT_RANK-1)); echo "$new_rank" > "$RANK_FILE"
      log "ADAPT DOWN: CPU=${cpu}% RAM=${ram}% speed=${speed}x -> $(rank_profile "$new_rank")"
      kill -TERM "$ffpid" 2>/dev/null || true; return 0
    fi
    if [ "$hard" = "1" ] && [ "$CURRENT_RANK" -eq 0 ]; then
      echo "$(date +%s) CPU=$cpu RAM=$ram speed=$speed" > "$RUNTIME/hard_limit_at_floor.status"
    fi
    if [ "$ADAPTIVE_ENABLE" = "1" ] && [ "$ADAPTIVE_UPSHIFT" = "1" ] && [ "$under" -ge "$ADAPTIVE_UNDERLOAD_SAMPLES" ] && [ "$CURRENT_RANK" -lt "$BASE_RANK" ] && [ $((now-last_change)) -ge "$ADAPTIVE_COOLDOWN_SEC" ]; then
      new_rank=$((CURRENT_RANK+1)); [ "$new_rank" -gt "$BASE_RANK" ] && new_rank="$BASE_RANK"; echo "$new_rank" > "$RANK_FILE"
      log "ADAPT UP: CPU=${cpu}% RAM=${ram}% speed=${speed}x -> $(rank_profile "$new_rank")"
      kill -TERM "$ffpid" 2>/dev/null || true; return 0
    fi
  done
}

# ---------- verified inputs --------------------------------------------------
if ! "$BASE_DIR/scripts/preflight.sh" >>"$LOG" 2>&1; then log "ERROR: preflight failed; refusing to start."; exit 1; fi
set -a; source "$RUNTIME/preflight.env" 2>/dev/null || true; set +a
EFFECTIVE_AUDIO="${PREFLIGHT_AUDIO:-${AUDIO_MODE:-pulse}}"; AUDIO_MODE="$EFFECTIVE_AUDIO"; export AUDIO_MODE

ensure_ui_profile(){
  local want have need=0
  want="${PROFILE}:${STREAM_WIDTH}x${STREAM_HEIGHT}:${AUDIO_MODE}"
  have="$(cat "$UI_SIG_FILE" 2>/dev/null || true)"
  [ "$want" != "$have" ] && need=1
  [ -f "$RUNTIME/quran-xvfb.pid" ] && kill -0 "$(cat "$RUNTIME/quran-xvfb.pid" 2>/dev/null)" 2>/dev/null || need=1
  [ -f "$RUNTIME/quran-chrome.pid" ] && kill -0 "$(cat "$RUNTIME/quran-chrome.pid" 2>/dev/null)" 2>/dev/null || need=1
  if [ "$need" -eq 1 ]; then
    log "UI RECONFIGURE: $want"
    "$BASE_DIR/scripts/stop_ui.sh" >/dev/null 2>&1 || true
    "$BASE_DIR/scripts/broadcast_ui.sh" >>"$LOG" 2>&1
    echo "$want" > "$UI_SIG_FILE"
  fi
}
trap 'touch "$STOP_FLAG"; "$BASE_DIR/scripts/stop_ui.sh" >/dev/null 2>&1 || true' EXIT INT TERM
rm -f "$STOP_FLAG"

# ---------- encode loop ------------------------------------------------------
while [ ! -f "$STOP_FLAG" ]; do
  CURRENT_RANK="$(cat "$RANK_FILE" 2>/dev/null || echo "$BASE_RANK")"; [[ "$CURRENT_RANK" =~ ^[0-6]$ ]] || CURRENT_RANK="$BASE_RANK"; [ "$CURRENT_RANK" -gt "$BASE_RANK" ] && CURRENT_RANK="$BASE_RANK"
  load_profile "$CURRENT_RANK"; AUDIO_MODE="$EFFECTIVE_AUDIO"; export AUDIO_MODE
  build_outputs; apply_egress_guard; ensure_ui_profile; rm -f "$PROGRESS"

  AUDIO_INPUT=()
  if [ "$EFFECTIVE_AUDIO" = "file" ]; then
    "$BASE_DIR/scripts/build_audio_playlist.sh" >>"$LOG" 2>&1 || true
    if [ -s "$RUNTIME/audio_playlist.txt" ]; then AUDIO_INPUT=(-re -stream_loop -1 -f concat -safe 0 -probesize 50k -analyzeduration 0 -thread_queue_size 64 -fflags +genpts -i "$RUNTIME/audio_playlist.txt"); else AUDIO_INPUT=(-thread_queue_size 64 -f pulse -i quran_sink.monitor); fi
  else AUDIO_INPUT=(-thread_queue_size 128 -f pulse -i quran_sink.monitor); fi

  VAAPI_PRE=(); VF="format=yuv420p"
  if [ "${PREFLIGHT_HW_OK:-}" = "nvenc" ]; then VARGS=(-c:v h264_nvenc -preset p4 -tune ll -rc cbr)
  elif [ "${PREFLIGHT_HW_OK:-}" = "vaapi" ] && [ "${HW_ALLOW_EXPERIMENTAL:-0}" = "1" ]; then VAAPI_PRE=(-vaapi_device /dev/dri/renderD128); VF="format=nv12,hwupload"; VARGS=(-c:v h264_vaapi -bf 2)
  else VARGS=(-c:v libx264 -preset "$FFMPEG_PRESET" -tune "$FFMPEG_TUNE" -threads "$FFMPEG_THREADS"); [ -n "${X264_PARAMS:-}" ] && VARGS+=(-x264-params "$X264_PARAMS"); fi
  GOP=$((STREAM_FPS*2))

  log "START: profile=$PROFILE ${STREAM_WIDTH}x${STREAM_HEIGHT}@${STREAM_FPS} targets=$TARGET_COUNT CPU target/hard=${CPU_TARGET}/${CPU_HARD_LIMIT}% audio=$EFFECTIVE_AUDIO hw=${PREFLIGHT_HW_OK:-cpu}"
  ffmpeg -hide_banner -loglevel warning -nostdin \
    "${VAAPI_PRE[@]}" -f x11grab -framerate "$STREAM_FPS" -video_size "${STREAM_WIDTH}x${STREAM_HEIGHT}" -draw_mouse 0 -thread_queue_size 64 -probesize 32k -analyzeduration 0 -i ":$DISPLAY_NUM.0" \
    "${AUDIO_INPUT[@]}" -map 0:v:0 -map 1:a:0 -vf "$VF" \
    "${VARGS[@]}" -b:v "$VIDEO_BITRATE" -maxrate "$MAX_BITRATE" -bufsize "$BUF_SIZE" \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -r "$STREAM_FPS" \
    -c:a aac -b:a "$AUDIO_BITRATE" -ar "$AUDIO_SAMPLERATE" -ac "${AUDIO_CHANNELS:-2}" -af "aresample=${AUDIO_SAMPLERATE}:async=1:first_pts=0" \
    -progress "$PROGRESS" -stats_period "$ADAPTIVE_SAMPLE_SEC" -f tee "$TEE_OUTPUT" >>"$LOG" 2>&1 &
  FFPID=$!
  adaptive_monitor "$FFPID" & MONPID=$!
  wait "$FFPID" || true
  kill "$MONPID" 2>/dev/null || true; wait "$MONPID" 2>/dev/null || true
  [ -f "$STOP_FLAG" ] && break
  log "Encoder stopped/reconfigured; restarting in 3s..."; sleep 3
done
log "Universal stream stopped."
