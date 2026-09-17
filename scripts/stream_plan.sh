#!/usr/bin/env bash
# ==============================================================================
# QuranLiveStream — adaptive stream planner
# Produces runtime/stream_plan.tsv. Each line:
# group|layout|profile|codec|display|targets_csv
# ==============================================================================
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE_DIR"
[ -f .env ] && { set -a; source .env 2>/dev/null; set +a; } || true
source "$BASE_DIR/scripts/platforms.sh"
quran_targets_load
RUNTIME="$BASE_DIR/runtime"; mkdir -p "$RUNTIME"
PLAN="$RUNTIME/stream_plan.tsv"; SUMMARY="$RUNTIME/stream_plan.txt"

rank(){ quran_profile_rank "$1"; }
prof(){ quran_profile_at "$1"; }

# Hardware/benchmark ceiling. A manual STREAM_PROFILE can lower the ceiling,
# but universal mode never lets it force a weak host above measured capacity.
REQUESTED="${STREAM_PROFILE:-auto}"
unset STREAM_PROFILE || true
# shellcheck disable=SC1091
source "$BASE_DIR/scripts/hardware_profile.sh"
HW_PROFILE="$PROFILE"; HW_RANK="$(rank "$HW_PROFILE")"
GLOBAL_RANK="$HW_RANK"
if [ -n "$REQUESTED" ] && [ "${REQUESTED,,}" != "auto" ]; then
  REQ_RANK="$(rank "${REQUESTED,,}")"
  [ "$REQ_RANK" -lt "$GLOBAL_RANK" ] && GLOBAL_RANK="$REQ_RANK"
fi
if [ -f "$RUNTIME/governor.env" ] && [ "${RESOURCE_GOVERNOR:-1}" != "0" ]; then
  # shellcheck disable=SC1091
  source "$RUNTIME/governor.env" 2>/dev/null || true
  if [ -n "${GOVERNOR_PROFILE:-}" ]; then
    GOV_RANK="$(rank "$GOVERNOR_PROFILE")"
    [ "$GOV_RANK" -lt "$GLOBAL_RANK" ] && GLOBAL_RANK="$GOV_RANK"
  fi
fi
GLOBAL_PROFILE="$(prof "$GLOBAL_RANK")"

CPU_N="$(nproc 2>/dev/null || echo 1)"
RAM_MB="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 1024)"
case "$CPU_N" in ''|*[!0-9]*)CPU_N=1;; esac
case "$RAM_MB" in ''|*[!0-9]*)RAM_MB=1024;; esac
GPU_HINT=0
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -Eq ' h264_(nvenc|vaapi|qsv) '; then GPU_HINT=1; fi

POLICY="${QUALITY_POLICY:-auto}"
if [ "$POLICY" = "auto" ]; then
  # Split same-aspect destinations into their individual maxima only when the
  # host has enough headroom. Otherwise sharing an encoder wins decisively.
  if { [ "$GPU_HINT" -eq 1 ] && [ "$RAM_MB" -ge 4096 ]; } || { [ "$CPU_N" -ge 8 ] && [ "$RAM_MB" -ge 8192 ] && [ "$GLOBAL_RANK" -ge 4 ]; }; then
    POLICY=maximize
  else
    POLICY=efficient
  fi
fi
case "$POLICY" in efficient|maximize) ;; *) POLICY=efficient;; esac

TARGETS=()
while IFS= read -r t; do
  [ -n "$t" ] || continue
  quran_target_valid_name "$t" || { echo "Invalid target: $t" >&2; exit 1; }
  quran_target_uri "$t" >/dev/null 2>&1 || { echo "Missing RTMP credentials for target: $t" >&2; exit 1; }
  TARGETS+=("$t")
done < <(quran_targets_lines)
[ "${#TARGETS[@]}" -gt 0 ] || { echo "No targets selected" >&2; exit 1; }

# Accumulate groups in associative arrays. Key includes codec because codecs
# cannot share one tee encoder. In maximize mode rank is also part of the key.
declare -A G_TARGETS G_RANK G_LAYOUT G_CODEC
ORDER=()
for t in "${TARGETS[@]}"; do
  layout="$(quran_target_layout "$t")"
  maxp="$(quran_target_max_profile "$t")"; maxr="$(rank "$maxp")"
  desired="$GLOBAL_RANK"; [ "$maxr" -lt "$desired" ] && desired="$maxr"
  codec="$(quran_target_codec "$t")"
  if [ "$POLICY" = "maximize" ]; then key="${layout}:${codec}:${desired}"; else key="${layout}:${codec}"; fi
  if [ -z "${G_TARGETS[$key]+x}" ]; then
    ORDER+=("$key"); G_TARGETS[$key]="$t"; G_RANK[$key]="$desired"; G_LAYOUT[$key]="$layout"; G_CODEC[$key]="$codec"
  else
    G_TARGETS[$key]="${G_TARGETS[$key]},$t"
    # Efficient groups share the highest native quality accepted by ALL members.
    [ "$desired" -lt "${G_RANK[$key]}" ] && G_RANK[$key]="$desired"
  fi
done

: > "$PLAN"; : > "$SUMMARY"
DISPLAY_BASE="${QURAN_DISPLAY_BASE:-90}"
i=0
for key in "${ORDER[@]}"; do
  profile="$(prof "${G_RANK[$key]}")"; layout="${G_LAYOUT[$key]}"; codec="${G_CODEC[$key]}"
  display=$((DISPLAY_BASE+i)); group="g$i"; targets="${G_TARGETS[$key]}"
  read -r w h < <(quran_profile_dimensions "$profile" "$layout")
  printf '%s|%s|%s|%s|%s|%s\n' "$group" "$layout" "$profile" "$codec" "$display" "$targets" >> "$PLAN"
  printf '%s: %s %sx%s %s codec=%s targets=%s\n' "$group" "$layout" "$w" "$h" "$profile" "$codec" "$targets" >> "$SUMMARY"
  i=$((i+1))
done

{
  echo "policy=$POLICY"
  echo "hardware_ceiling=$HW_PROFILE"
  echo "active_ceiling=$GLOBAL_PROFILE"
  echo "groups=$i"
  cat "$SUMMARY"
} > "$SUMMARY.tmp" && mv "$SUMMARY.tmp" "$SUMMARY"
cat "$SUMMARY"
