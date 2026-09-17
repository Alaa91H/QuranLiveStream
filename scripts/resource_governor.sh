#!/usr/bin/env bash
# ==============================================================================
# Quran Live Stream — live resource governor
# Keeps sustained host pressure below the configured safety envelope by stepping
# quality down/up with hysteresis. It NEVER upgrades above the measured host
# benchmark ceiling. Default daemon interval: 15s.
# ==============================================================================
set -uo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE_DIR"
[ -f .env ] && { set -a; source .env 2>/dev/null; set +a; } || true
RUNTIME="$BASE_DIR/runtime"; LOG_DIR="$BASE_DIR/logs"
mkdir -p "$RUNTIME" "$LOG_DIR"
LOG="$LOG_DIR/resource_governor.log"
STATE="$RUNTIME/governor.state"
GOV_ENV="$RUNTIME/governor.env"
STATUS="$RUNTIME/resources.json"
INTERVAL="${RESOURCE_INTERVAL_SEC:-15}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [GOV] $*" | tee -a "$LOG"; }
rank() { case "$1" in nano)echo 0;; micro)echo 1;; eco)echo 2;; balanced)echo 3;; high)echo 4;; ultra)echo 5;; extreme)echo 6;; *)echo 1;; esac; }
profile_at() { case "$1" in 0)echo nano;;1)echo micro;;2)echo eco;;3)echo balanced;;4)echo high;;5)echo ultra;;*)echo extreme;; esac; }

sample_cpu_pct() {
  local a b idle1 idle2 total1 total2 dt di
  read -r _ a < <(grep '^cpu ' /proc/stat | sed 's/^cpu  //')
  read -ra v1 <<< "$a"
  idle1=$(( ${v1[3]:-0} + ${v1[4]:-0} ))
  total1=0; for n in "${v1[@]}"; do total1=$((total1+n)); done
  sleep 1
  read -r _ b < <(grep '^cpu ' /proc/stat | sed 's/^cpu  //')
  read -ra v2 <<< "$b"
  idle2=$(( ${v2[3]:-0} + ${v2[4]:-0} ))
  total2=0; for n in "${v2[@]}"; do total2=$((total2+n)); done
  dt=$((total2-total1)); di=$((idle2-idle1))
  if [ "$dt" -le 0 ]; then echo 0; else awk "BEGIN{printf \"%.0f\", 100*(1-$di/$dt)}"; fi
}

sample_mem_pct() {
  local total avail
  total="$(awk '/MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  avail="$(awk '/MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "${total:-0}" -le 0 ]; then echo 0; else awk "BEGIN{printf \"%.0f\", 100*(1-$avail/$total)}"; fi
}

restart_stream() {
  if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet quran-live.service 2>/dev/null; then
    systemctl --user restart quran-live.service >/dev/null 2>&1 || true
  fi
}

write_governor() {
  local p="$1" fps_cap="${2:-}" city_limit="${3:-}"
  {
    echo "GOVERNOR_PROFILE=$p"
    [ -n "$fps_cap" ] && echo "GOVERNOR_FPS_CAP=$fps_cap" || true
    [ -n "$city_limit" ] && echo "GOVERNOR_CITY_LIMIT=$city_limit" || true
    echo "GOVERNOR_CHANGED_TS=$(date +%s)"
  } > "$GOV_ENV.tmp"
  mv "$GOV_ENV.tmp" "$GOV_ENV"
}

cycle() {
  [ "${RESOURCE_GOVERNOR:-1}" = "0" ] && return 0
  [ -f "$RUNTIME/stream_active.flag" ] || return 0

  local cpu mem speed now active active_ts maxp maxr ar soft hard low high_hits low_hits last_change cooldown
  cpu="$(sample_cpu_pct)"; mem="$(sample_mem_pct)"; now="$(date +%s)"
  speed="$(tail -n 500 "$LOG_DIR/stream.log" 2>/dev/null | awk -F= '$1=="speed"{gsub(/x/,"",$2); v=$2} END{print v+0}')"
  active="micro"; active_ts=0
  if [ -f "$RUNTIME/active_profile.env" ]; then
    source "$RUNTIME/active_profile.env" 2>/dev/null || true
    active="${ACTIVE_PROFILE:-micro}"; active_ts="${ACTIVE_TS:-0}"
  fi
  if [ "$active_ts" -gt 0 ] && [ "$((now-active_ts))" -lt "${RESOURCE_STARTUP_GRACE_SEC:-90}" ]; then
    printf '{"ts":%s,"cpu_pct":%s,"mem_pct":%s,"speed_x":"%s","profile":"%s","state":"startup-grace"}\n' "$now" "$cpu" "$mem" "$speed" "$active" > "$STATUS"
    return 0
  fi

  maxp="${RESOURCE_MAX_PROFILE:-}"
  if [ -z "$maxp" ] && [ -f "$RUNTIME/host.env" ]; then
    source "$RUNTIME/host.env" 2>/dev/null || true
    maxp="${HOST_BENCH_PROFILE:-}"
  fi
  [ -n "$maxp" ] || maxp="$active"
  maxr="$(rank "$maxp")"; ar="$(rank "$active")"

  high_hits=0; low_hits=0; last_change=0
  [ -f "$STATE" ] && read -r high_hits low_hits last_change < "$STATE" || true
  case "$high_hits" in ''|*[!0-9]*) high_hits=0;; esac
  case "$low_hits" in ''|*[!0-9]*) low_hits=0;; esac
  case "$last_change" in ''|*[!0-9]*) last_change=0;; esac

  soft="${RESOURCE_CPU_SOFT:-85}"
  hard="${RESOURCE_CPU_HARD:-93}"
  local mem_soft="${RESOURCE_RAM_SOFT:-88}" mem_hard="${RESOURCE_RAM_HARD:-94}"
  low="${RESOURCE_CPU_LOW:-55}"
  local mem_low="${RESOURCE_RAM_LOW:-70}"
  cooldown="${RESOURCE_COOLDOWN_SEC:-300}"

  printf '{"ts":%s,"cpu_pct":%s,"mem_pct":%s,"speed_x":"%s","profile":"%s","ceiling":"%s","high_hits":%s,"low_hits":%s}\n' \
    "$now" "$cpu" "$mem" "$speed" "$active" "$maxp" "$high_hits" "$low_hits" > "$STATUS"

  if [ "$((now-last_change))" -lt "$cooldown" ]; then return 0; fi

  if [ "$cpu" -ge "$hard" ] || [ "$mem" -ge "$mem_hard" ]; then
    high_hits="${RESOURCE_HIGH_HITS:-3}"; low_hits=0
  elif awk "BEGIN{exit !($speed > 0 && $speed < ${RESOURCE_SPEED_SOFT:-0.95})}"; then
    high_hits=$((high_hits+1)); low_hits=0
  elif [ "$cpu" -ge "$soft" ] || [ "$mem" -ge "$mem_soft" ]; then
    high_hits=$((high_hits+1)); low_hits=0
  elif [ "$cpu" -le "$low" ] && [ "$mem" -le "$mem_low" ]; then
    low_hits=$((low_hits+1)); high_hits=0
  else
    high_hits=0; low_hits=0
  fi

  if [ "$high_hits" -ge "${RESOURCE_HIGH_HITS:-3}" ]; then
    local next fps_cap="" cities=""
    if [ "$ar" -gt 0 ]; then
      next="$(profile_at $((ar-1)))"
    else
      next="nano"; fps_cap=8
      if [ -f "$GOV_ENV" ]; then
        old_cap="$(grep '^GOVERNOR_FPS_CAP=' "$GOV_ENV" 2>/dev/null | cut -d= -f2 || true)"
        [ "${old_cap:-}" = "8" ] && fps_cap=6
        [ "${old_cap:-}" = "6" ] && fps_cap=5
      fi
      cities=2
    fi
    log "Pressure cpu=${cpu}% mem=${mem}% speed=${speed}x: $active -> $next${fps_cap:+ @${fps_cap}fps cap}. Restarting cleanly."
    write_governor "$next" "$fps_cap" "$cities"
    echo "0 0 $now" > "$STATE"
    restart_stream
    "$BASE_DIR/scripts/notify_telegram.sh" "⚠️ QuranLive auto-tune: CPU ${cpu}% / RAM ${mem}% — profile $active → $next${fps_cap:+ (${fps_cap}fps cap)}." >/dev/null 2>&1 || true
    return 0
  fi

  if [ "${RESOURCE_AUTO_UPGRADE:-1}" = "1" ] && [ "$low_hits" -ge "${RESOURCE_LOW_HITS:-80}" ] && [ "$ar" -lt "$maxr" ]; then
    local next
    next="$(profile_at $((ar+1)))"
    log "Long low-pressure window cpu=${cpu}% mem=${mem}%: $active -> $next (ceiling $maxp)."
    write_governor "$next" "" ""
    echo "0 0 $now" > "$STATE"
    restart_stream
    return 0
  fi

  echo "$high_hits $low_hits $last_change" > "$STATE"
}

if [ "${1:-}" = "--once" ]; then cycle; exit 0; fi
log "Resource governor started: interval=${INTERVAL}s softCPU=${RESOURCE_CPU_SOFT:-85}% hardCPU=${RESOURCE_CPU_HARD:-93}% softRAM=${RESOURCE_RAM_SOFT:-88}%"
while true; do cycle || true; sleep "$INTERVAL"; done
