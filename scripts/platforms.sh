#!/usr/bin/env bash
# ==============================================================================
# QuranLiveStream — platform capability registry
# Exact-canvas rule: every stream is rendered at its final native dimensions.
# No scale, crop, pad or letterbox is required in the streaming path.
# ==============================================================================

quran_targets_load() {
  local base_dir="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  if [ -f "$base_dir/runtime/targets.env" ]; then
    # shellcheck disable=SC1090
    source "$base_dir/runtime/targets.env" 2>/dev/null || true
  fi
  STREAM_TARGETS="${STREAM_TARGETS:-youtube}"
  export STREAM_TARGETS
}

quran_target_prefix() {
  local t="${1:-}"
  printf '%s' "$t" | tr '[:lower:]-.' '[:upper:]__' | tr -cd 'A-Z0-9_'
}

quran_targets_lines() {
  local raw="${STREAM_TARGETS:-youtube}"
  raw="${raw//;/,}"
  raw="${raw// /,}"
  printf '%s\n' "$raw" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | awk 'NF && !seen[$0]++'
}

quran_target_valid_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

quran_target_uri() {
  local target="${1:-}" prefix full_var url_var key_var full url key
  quran_target_valid_name "$target" || return 2
  prefix="$(quran_target_prefix "$target")"
  full_var="${prefix}_RTMP_TARGET"
  url_var="${prefix}_RTMP_URL"
  key_var="${prefix}_STREAM_KEY"
  full="${!full_var:-}"
  if [ -n "$full" ]; then printf '%s' "$full"; return 0; fi
  url="${!url_var:-}"; key="${!key_var:-}"
  [ -n "$url" ] && [ -n "$key" ] || return 1
  printf '%s/%s' "${url%/}" "$key"
}

quran_target_redacted() {
  local target="${1:-}" uri host
  uri="$(quran_target_uri "$target" 2>/dev/null || true)"
  [ -n "$uri" ] || { printf '%s' "$target"; return 0; }
  host="$(printf '%s' "$uri" | sed -E 's#^[a-zA-Z0-9+.-]+://##; s#/.*##; s#:[0-9]+$##')"
  printf '%s(%s)' "$target" "${host:-unknown-host}"
}

quran_target_host_port() {
  local uri="${1:-}" scheme authority host port
  scheme="${uri%%://*}"; authority="${uri#*://}"; authority="${authority%%/*}"
  host="$authority"; port=""
  if [[ "$authority" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
  elif [[ "$authority" =~ ^([^:]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
  fi
  if [ -z "$port" ]; then
    case "$scheme" in rtmps) port=443;; rtmp) port=1935;; *) port=0;; esac
  fi
  printf '%s %s' "$host" "$port"
}

quran_profile_rank() {
  case "${1:-}" in nano)echo 0;; micro)echo 1;; eco)echo 2;; balanced)echo 3;; high)echo 4;; ultra)echo 5;; extreme)echo 6;; *)echo 1;; esac
}
quran_profile_at() {
  case "${1:-0}" in 0)echo nano;;1)echo micro;;2)echo eco;;3)echo balanced;;4)echo high;;5)echo ultra;;*)echo extreme;; esac
}

# Native dimensions for each aspect family. These are final render AND encoder
# dimensions, so no scaling/cropping/padding is introduced after Chromium.
quran_profile_dimensions() {
  local profile="${1:-micro}" layout="${2:-landscape}" w h
  case "$profile" in
    nano) w=640; h=360;;
    micro) w=854; h=480;;
    eco) w=1280; h=720;;
    balanced) w=1920; h=1080;;
    high) w=2560; h=1440;;
    ultra) w=3840; h=2160;;
    extreme) w=7680; h=4320;;
    *) w=854; h=480;;
  esac
  case "$layout" in
    portrait) printf '%s %s' "$h" "$w";;
    square)
      case "$profile" in nano) w=360;; micro) w=480;; eco) w=720;; balanced) w=1080;; high) w=1440;; ultra) w=2160;; extreme) w=4320;; esac
      printf '%s %s' "$w" "$w";;
    *) printf '%s %s' "$w" "$h";;
  esac
}

quran_target_layout() {
  local target="${1:-}" prefix var v
  prefix="$(quran_target_prefix "$target")"; var="${prefix}_LAYOUT"; v="${!var:-}"
  case "${v,,}" in landscape|horizontal|16:9) echo landscape; return;; portrait|vertical|9:16) echo portrait; return;; square|1:1) echo square; return;; esac
  case "${target,,}" in
    tiktok|instagram|reels|youtube-vertical|youtube_vertical|shorts) echo portrait;;
    *) echo landscape;;
  esac
}

quran_target_max_profile() {
  local target="${1:-}" prefix var v
  prefix="$(quran_target_prefix "$target")"; var="${prefix}_MAX_PROFILE"; v="${!var:-}"
  if [ -n "$v" ]; then echo "${v,,}"; return; fi
  case "${target,,}" in
    youtube|youtube-vertical|youtube_vertical) echo ultra;;      # verified Live guidance up to 4K
    twitch) [ "${TWITCH_ALLOW_1440P:-0}" = "1" ] && echo high || echo balanced;;
    kick|tiktok|instagram|facebook|reels|shorts) echo balanced;;
    *) echo extreme;;
  esac
}

quran_target_max_fps() {
  local target="${1:-}" prefix var v
  prefix="$(quran_target_prefix "$target")"; var="${prefix}_MAX_FPS"; v="${!var:-}"
  [[ "$v" =~ ^[0-9]+$ ]] && { echo "$v"; return; }
  case "${target,,}" in instagram|reels) echo 30;; *) echo 60;; esac
}

quran_target_max_bitrate_kbit() {
  local target="${1:-}" prefix var value
  prefix="$(quran_target_prefix "$target")"; var="${prefix}_MAX_VIDEO_BITRATE"; value="${!var:-}"
  if [ -n "$value" ]; then
    case "$value" in *[kK])echo "${value%[kK]}";; *[mM])echo "$(( ${value%[mM]} * 1000 ))";; *[!0-9]*)echo 0;; *)echo "$value";; esac
    return
  fi
  case "${target,,}" in
    youtube|youtube-vertical|youtube_vertical) echo 40000;;
    kick) echo 8000;;
    twitch) [ "${TWITCH_ALLOW_1440P:-0}" = "1" ] && echo 7500 || echo 6000;;
    tiktok|instagram|facebook|reels|shorts) echo 6000;;
    *) echo 0;;
  esac
}

quran_target_codec() {
  local target="${1:-}" prefix var v
  prefix="$(quran_target_prefix "$target")"; var="${prefix}_VIDEO_CODEC"; v="${!var:-}"
  [ -n "$v" ] && { echo "${v,,}"; return; }
  # H.264 is the safe intersection for RTMP platforms; YouTube-specific HEVC/AV1
  # can be explicitly requested only when that destination is in its own group.
  echo h264
}

quran_target_audio_rate() {
  local target="${1:-}" prefix var v
  prefix="$(quran_target_prefix "$target")"; var="${prefix}_AUDIO_RATE"; v="${!var:-}"
  [[ "$v" =~ ^[0-9]+$ ]] && { echo "$v"; return; }
  case "${target,,}" in kick|twitch|facebook|tiktok|instagram) echo 48000;; *) echo 44100;; esac
}

quran_layout_default_cities() {
  local layout="${1:-landscape}" profile="${2:-balanced}"
  case "$layout" in
    portrait) case "$profile" in nano|micro)echo 1;; *)echo 2;; esac;;
    square) case "$profile" in nano|micro)echo 2;; *)echo 3;; esac;;
    *) case "$profile" in nano)echo 2;; micro)echo 3;; eco)echo 5;; *)echo 6;; esac;;
  esac
}

quran_resolve_layout() {
  local requested="${STREAM_LAYOUT:-auto}" t first="" mixed=0 current
  case "${requested,,}" in landscape|horizontal)echo landscape; return;; portrait|vertical)echo portrait; return;; square)echo square; return;; esac
  while IFS= read -r t; do
    [ -n "$t" ] || continue; current="$(quran_target_layout "$t")"
    [ -z "$first" ] && first="$current"
    [ "$current" != "$first" ] && mixed=1
  done < <(quran_targets_lines)
  [ "$mixed" -eq 0 ] && echo "${first:-landscape}" || echo mixed
}
