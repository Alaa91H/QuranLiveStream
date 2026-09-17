#!/usr/bin/env bash
# Shared target resolver for QuranLiveStream.
# Supports any RTMP/RTMPS destination selected through STREAM_TARGETS.
# A target named "youtube" resolves either:
#   YOUTUBE_RTMP_TARGET=<full rtmp(s)://.../key>
# or:
#   YOUTUBE_RTMP_URL=<base rtmp(s)://...>
#   YOUTUBE_STREAM_KEY=<secret>

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
  if [ -n "$full" ]; then
    printf '%s' "$full"
    return 0
  fi
  url="${!url_var:-}"
  key="${!key_var:-}"
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
  scheme="${uri%%://*}"
  authority="${uri#*://}"
  authority="${authority%%/*}"
  host="$authority"
  port=""
  if [[ "$authority" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
  elif [[ "$authority" =~ ^([^:]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
  fi
  if [ -z "$port" ]; then
    case "$scheme" in
      rtmps) port=443 ;;
      rtmp) port=1935 ;;
      *) port=0 ;;
    esac
  fi
  printf '%s %s' "$host" "$port"
}

quran_target_max_bitrate_kbit() {
  local target="${1:-}" prefix var value
  prefix="$(quran_target_prefix "$target")"
  var="${prefix}_MAX_VIDEO_BITRATE"
  value="${!var:-}"
  case "$value" in
    *[kK]) printf '%s' "${value%[kK]}" ;;
    *[mM]) printf '%s' "$(( ${value%[mM]} * 1000 ))" ;;
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$value" ;;
  esac
}

quran_resolve_layout() {
  local requested="${STREAM_LAYOUT:-auto}" t any=0 all_vertical=1
  case "${requested,,}" in
    landscape|horizontal) printf 'landscape'; return 0 ;;
    portrait|vertical) printf 'portrait'; return 0 ;;
  esac
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    any=1
    case "${t,,}" in
      tiktok|instagram|reels|shorts) ;;
      *) all_vertical=0 ;;
    esac
  done < <(quran_targets_lines)
  if [ "$any" -eq 1 ] && [ "$all_vertical" -eq 1 ]; then
    printf 'portrait'
  else
    printf 'landscape'
  fi
}
