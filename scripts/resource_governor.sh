#!/usr/bin/env bash
# ==============================================================================
# QuranLiveStream — global live resource governor
# Watches total host CPU/RAM and the slowest active encoder. It lowers/raises the
# global quality ceiling with hysteresis and never upgrades beyond benchmark.
# ==============================================================================
set -uo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"; cd "$BASE_DIR"
[ -f .env ] && { set -a; source .env 2>/dev/null; set +a; } || true
source "$BASE_DIR/scripts/platforms.sh"
RUNTIME="$BASE_DIR/runtime"; LOG_DIR="$BASE_DIR/logs"; mkdir -p "$RUNTIME" "$LOG_DIR"
LOG="$LOG_DIR/resource_governor.log"; STATE="$RUNTIME/governor.state"; GOV_ENV="$RUNTIME/governor.env"; STATUS="$RUNTIME/resources.json"
INTERVAL="${RESOURCE_INTERVAL_SEC:-10}"
log(){ echo "[$(date '+%F %T')] [GOV] $*" | tee -a "$LOG"; }
rank(){ quran_profile_rank "$1"; }; prof(){ quran_profile_at "$1"; }

sample_cpu_pct(){
  local l1 l2 t1=0 t2=0 i1 i2 n
  read -ra l1 < <(awk '/^cpu /{for(i=2;i<=NF;i++)printf "%s ",$i;exit}' /proc/stat)
  i1=$((${l1[3]:-0}+${l1[4]:-0})); for n in "${l1[@]}"; do t1=$((t1+n)); done
  sleep 1
  read -ra l2 < <(awk '/^cpu /{for(i=2;i<=NF;i++)printf "%s ",$i;exit}' /proc/stat)
  i2=$((${l2[3]:-0}+${l2[4]:-0})); for n in "${l2[@]}"; do t2=$((t2+n)); done
  [ $((t2-t1)) -gt 0 ] && awk "BEGIN{printf \"%.0f\",100*(1-($i2-$i1)/($t2-$t1))}" || echo 0
}
sample_mem_pct(){ awk '/MemTotal:/{t=$2}/MemAvailable:/{a=$2}END{if(t>0)printf "%.0f",100*(t-a)/t;else print 0}' /proc/meminfo; }

slowest_speed(){
  local f s min=""
  for f in "$RUNTIME"/groups/*/ffmpeg.progress; do
    [ -f "$f" ] || continue
    s="$(grep '^speed=' "$f" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d 'x' || true)"
    [[ "$s" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
    if [ -z "$min" ] || awk -v a="$s" -v b="$min" 'BEGIN{exit !(a<b)}'; then min="$s"; fi
  done
  echo "${min:-1.00}"
}

benchmark_ceiling(){
  local requested="${STREAM_PROFILE:-auto}" hp hr rr
  unset STREAM_PROFILE || true
  source "$BASE_DIR/scripts/hardware_profile.sh" >/dev/null 2>&1
  hp="$PROFILE"; hr="$(rank "$hp")"
  if [ -n "$requested" ] && [ "${requested,,}" != "auto" ]; then rr="$(rank "${requested,,}")"; [ "$rr" -lt "$hr" ] && hp="$(prof "$rr")"; fi
  echo "$hp"
}

restart_stream(){
  if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet quran-live.service 2>/dev/null; then
    systemctl --user restart quran-live.service >/dev/null 2>&1 || true
  fi
}
write_governor(){
  local p="$1" fps="${2:-}" cities="${3:-}"
  {
    echo "GOVERNOR_PROFILE=$p"
    [ -n "$fps" ] && echo "GOVERNOR_FPS_CAP=$fps"
    [ -n "$cities" ] && echo "GOVERNOR_CITY_LIMIT=$cities"
    echo "GOVERNOR_CHANGED_TS=$(date +%s)"
  } > "$GOV_ENV.tmp" && mv "$GOV_ENV.tmp" "$GOV_ENV"
}

cycle(){
  [ "${RESOURCE_GOVERNOR:-1}" = "0" ] && return 0
  [ -f "$RUNTIME/stream_active.flag" ] || return 0
  local cpu mem speed now ceiling cr active ar high=0 low=0 changed=0
  cpu="$(sample_cpu_pct)"; mem="$(sample_mem_pct)"; speed="$(slowest_speed)"; now="$(date +%s)"
  ceiling="$(benchmark_ceiling)"; cr="$(rank "$ceiling")"
  active="$ceiling"
  if [ -f "$GOV_ENV" ]; then
    source "$GOV_ENV" 2>/dev/null || true
    [ -n "${GOVERNOR_PROFILE:-}" ] && active="$GOVERNOR_PROFILE"
  fi
  ar="$(rank "$active")"
  [ -f "$STATE" ] && read -r high low changed < "$STATE" || true
  case "$high" in ''|*[!0-9]*)high=0;; esac; case "$low" in ''|*[!0-9]*)low=0;; esac; case "$changed" in ''|*[!0-9]*)changed=0;; esac

  local soft="${RESOURCE_CPU_SOFT:-78}" hard="${RESOURCE_CPU_HARD:-88}" msoft="${RESOURCE_RAM_SOFT:-82}" mhard="${RESOURCE_RAM_HARD:-89}"
  local lowcpu="${RESOURCE_CPU_LOW:-52}" lowmem="${RESOURCE_RAM_LOW:-68}" minspd="${RESOURCE_SPEED_SOFT:-0.97}"
  local hits="${RESOURCE_HIGH_HITS:-3}" lowhits="${RESOURCE_LOW_HITS:-60}" cooldown="${RESOURCE_COOLDOWN_SEC:-240}"
  groups="$(find "$RUNTIME/groups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  printf '{"ts":%s,"cpu_pct":%s,"mem_pct":%s,"slowest_speed_x":"%s","profile":"%s","ceiling":"%s","groups":%s,"high_hits":%s,"low_hits":%s}\n' "$now" "$cpu" "$mem" "$speed" "$active" "$ceiling" "${groups:-0}" "$high" "$low" > "$STATUS"

  # Hard limit reacts in one cycle; soft pressure requires persistence.
  if [ "$cpu" -ge "$hard" ] || [ "$mem" -ge "$mhard" ]; then high="$hits"; low=0
  elif awk -v s="$speed" -v m="$minspd" 'BEGIN{exit !(s>0 && s<m)}'; then high=$((high+1)); low=0
  elif [ "$cpu" -ge "$soft" ] || [ "$mem" -ge "$msoft" ]; then high=$((high+1)); low=0
  elif [ "$cpu" -le "$lowcpu" ] && [ "$mem" -le "$lowmem" ] && awk -v s="$speed" 'BEGIN{exit !(s>=1.0)}'; then low=$((low+1)); high=0
  else high=0; low=0; fi

  if [ "$high" -ge "$hits" ] && [ $((now-changed)) -ge 20 ]; then
    local next fps="" cities=""
    if [ "$ar" -gt 0 ]; then next="$(prof $((ar-1)))"
    else
      next=nano
      oldfps="${GOVERNOR_FPS_CAP:-10}"
      case "$oldfps" in ''|*[!0-9]*)oldfps=10;; esac
      if [ "$oldfps" -gt 8 ]; then fps=8; elif [ "$oldfps" -gt 6 ]; then fps=6; elif [ "$oldfps" -gt 5 ]; then fps=5; else fps=4; fi
      cities=1
    fi
    log "Pressure CPU=${cpu}% RAM=${mem}% slowest=${speed}x: $active -> $next${fps:+ @${fps}fps}."
    write_governor "$next" "$fps" "$cities"; echo "0 0 $now" > "$STATE"; restart_stream
    "$BASE_DIR/scripts/notify_telegram.sh" "⚠️ QuranLive adaptive downshift: CPU ${cpu}% RAM ${mem}% speed ${speed}x → $next${fps:+/${fps}fps}." >/dev/null 2>&1 || true
    return
  fi

  if [ "${RESOURCE_AUTO_UPGRADE:-1}" = "1" ] && [ "$low" -ge "$lowhits" ] && [ "$ar" -lt "$cr" ] && [ $((now-changed)) -ge "$cooldown" ]; then
    next="$(prof $((ar+1)))"
    log "Stable headroom CPU=${cpu}% RAM=${mem}% speed=${speed}x: $active -> $next (ceiling $ceiling)."
    write_governor "$next" "" ""; echo "0 0 $now" > "$STATE"; restart_stream; return
  fi
  echo "$high $low $changed" > "$STATE"
}

if [ "${1:-}" = "--once" ]; then cycle; exit 0; fi
log "Governor: interval=${INTERVAL}s CPU soft/hard=${RESOURCE_CPU_SOFT:-78}/${RESOURCE_CPU_HARD:-88}% RAM=${RESOURCE_RAM_SOFT:-82}/${RESOURCE_RAM_HARD:-89}%"
while true; do cycle || true; sleep "$INTERVAL"; done
