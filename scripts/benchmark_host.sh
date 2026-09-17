#!/bin/bash
# ==============================================================================
# QuranLiveStream — progressive encode self-benchmark
# Starts with the tiny-host 480p baseline, then only probes higher real profiles
# when CPU/RAM justify it. Hardware encoders must pass real 1440p/4K smoke tests.
# Writes the maximum sustainable quality ceiling to runtime/host.env.
# ==============================================================================
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$BASE_DIR/runtime"; LOG_DIR="$BASE_DIR/logs"
mkdir -p "$RUNTIME" "$LOG_DIR"
ENV_OUT="$RUNTIME/host.env"; LOG="$LOG_DIR/benchmark.log"
log(){ echo "[$(date '+%F %T')] [BENCH] $*" | tee -a "$LOG"; }

if [ "${1:-}" != "--force" ] && [ -f "$ENV_OUT" ]; then
  MTIME="$(stat -c%Y "$ENV_OUT" 2>/dev/null || stat -f%m "$ENV_OUT" 2>/dev/null || echo 0)"
  case "$MTIME" in ''|*[!0-9]*)MTIME=0;; esac
  AGE=$(( $(date +%s)-MTIME ))
  if [ "$AGE" -lt "$((7*86400))" ]; then log "Fresh host.env ($((AGE/3600))h), skipping; use --force to retest."; exit 0; fi
fi
command -v ffmpeg >/dev/null 2>&1 || { log "ERROR: ffmpeg missing."; exit 1; }

MEM_MB="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
CPU_N="$(nproc 2>/dev/null || echo 1)"
case "$MEM_MB" in ''|*[!0-9]*)MEM_MB=0;; esac; case "$CPU_N" in ''|*[!0-9]*)CPU_N=1;; esac
eval "$("$BASE_DIR/scripts/detect_host.sh")" 2>/dev/null || true

parse_speed_x(){
  awk '{for(i=1;i<=NF;i++) if($i~/^speed=/){split($i,a,"=");sub(/x$/,"",a[2]);if(a[2]+0>0)v=a[2]}}END{print v+0}' "$1" 2>/dev/null
}
run_cpu_probe(){
  local size="$1" fps="$2" preset="$3" dur="${4:-5}" out="$RUNTIME/bench_probe.log" speed
  rm -f "$out"
  ffmpeg -hide_banner -nostdin -y -f lavfi -i "smptehdbars=s=${size}:r=${fps}:d=${dur}" -an -pix_fmt yuv420p \
    -c:v libx264 -preset "$preset" -tune zerolatency -g $((fps*2)) -keyint_min $((fps*2)) -sc_threshold 0 -f null - 2>"$out" || true
  speed="$(parse_speed_x "$out")"; rm -f "$out"; echo "${speed:-0}"
}

# Baseline tiny-host benchmark + CPU-steal discount.
W=854; H=480; FPS=10; DUR=12; BLOG="$RUNTIME/bench_tmp.log"; rm -f "$BLOG"
read -r _ u0 n0 s0 i0 w0 x0 y0 z0 st0 _rest < <(grep '^cpu ' /proc/stat)
T0=$((u0+n0+s0+i0+w0+x0+y0+z0+st0))
ffmpeg -hide_banner -nostdin -y -f lavfi -i "smptehdbars=s=${W}x${H}:r=${FPS}:d=${DUR}" -an -pix_fmt yuv420p \
  -c:v libx264 -preset ultrafast -tune zerolatency -b:v 800k -maxrate 800k -bufsize 1600k \
  -g 20 -keyint_min 20 -sc_threshold 0 -bf 0 -refs 1 -x264-params scenecut=0 -f null - 2>"$BLOG" || true
read -r _ u1 n1 s1 i1 w1 x1 y1 z1 st1 _rest < <(grep '^cpu ' /proc/stat)
T1=$((u1+n1+s1+i1+w1+x1+y1+z1+st1))
BASE_SPEED="$(parse_speed_x "$BLOG")"; rm -f "$BLOG"
BENCH_FPS="$(awk -v s="${BASE_SPEED:-0}" -v f="$FPS" 'BEGIN{printf "%.1f",s*f}')"
STEAL_PCT="$(awk "BEGIN{d=$((T1-T0));s=$((st1-st0));if(d>0)printf \"%.1f\",100*s/d;else print 0}")"
EFF_FPS="$(awk -v f="$BENCH_FPS" -v s="$STEAL_PCT" 'BEGIN{printf "%.0f",f*(1-s/100)}')"
EFF_INT="${EFF_FPS%.*}"; case "$EFF_INT" in ''|*[!0-9]*)EFF_INT=0;; esac

if [ "$EFF_INT" -lt 12 ]; then BENCH_PROFILE=nano
elif [ "$EFF_INT" -le 70 ]; then BENCH_PROFILE=micro
elif [ "$EFF_INT" -le 200 ]; then BENCH_PROFILE=eco
else BENCH_PROFILE=balanced
fi

# RAM/steal safety caps for the base decision.
if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 700 ]; then BENCH_PROFILE=nano
elif [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 900 ]; then case "$BENCH_PROFILE" in balanced|eco)BENCH_PROFILE=micro;; esac
elif [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 1800 ]; then [ "$BENCH_PROFILE" = balanced ] && BENCH_PROFILE=eco || true
fi
STEAL_INT="${STEAL_PCT%.*}"; [ "${STEAL_INT:-0}" -gt 20 ] && case "$BENCH_PROFILE" in balanced|eco)BENCH_PROFILE=micro;; esac

HOST_HW_OK=cpu; HOST_HW_1440=0; HOST_HW_4K=0
# NVENC: tiny probe proves device works; real-size probes prove target tier works.
if command -v timeout >/dev/null 2>&1 && ffmpeg -hide_banner -encoders 2>/dev/null | grep -q ' h264_nvenc '; then
  if timeout 20 ffmpeg -hide_banner -loglevel error -nostdin -y -f lavfi -i 'nullsrc=s=640x360:r=10:d=2' \
      -c:v h264_nvenc -preset p1 -b:v 800k -f null - >/dev/null 2>&1; then
    HOST_HW_OK=nvenc
    if [ "$MEM_MB" -ge 6000 ] && timeout 25 ffmpeg -hide_banner -loglevel error -nostdin -y \
      -f lavfi -i 'nullsrc=s=2560x1440:r=60:d=3' -c:v h264_nvenc -preset p4 -rc cbr -b:v 16000k -f null - >/dev/null 2>&1; then
      HOST_HW_1440=1
    fi
    if [ "$MEM_MB" -ge 12000 ] && [ "$CPU_N" -ge 4 ] && timeout 30 ffmpeg -hide_banner -loglevel error -nostdin -y \
      -f lavfi -i 'nullsrc=s=3840x2160:r=60:d=3' -c:v h264_nvenc -preset p4 -rc cbr -b:v 30000k -f null - >/dev/null 2>&1; then
      HOST_HW_4K=1
    fi
  fi
fi

# CPU-only higher tiers: test the actual output class rather than extrapolating
# from the 480p probe. Require >1.20x realtime for render/network headroom.
CPU_1440_SPEED=0; CPU_4K_SPEED=0
if [ "$HOST_HW_OK" = cpu ] && [ "$CPU_N" -ge 6 ] && [ "$MEM_MB" -ge 8000 ] && [ "$STEAL_INT" -le 10 ]; then
  CPU_1440_SPEED="$(run_cpu_probe 2560x1440 60 ultrafast 4)"
  if awk -v s="$CPU_1440_SPEED" 'BEGIN{exit !(s>=1.25)}'; then BENCH_PROFILE=high; fi
fi
if [ "$HOST_HW_OK" = cpu ] && [ "$CPU_N" -ge 16 ] && [ "$MEM_MB" -ge 16000 ] && [ "$STEAL_INT" -le 5 ]; then
  CPU_4K_SPEED="$(run_cpu_probe 3840x2160 60 ultrafast 4)"
  if awk -v s="$CPU_4K_SPEED" 'BEGIN{exit !(s>=1.30)}'; then BENCH_PROFILE=ultra; fi
fi

if [ "$HOST_HW_OK" = nvenc ]; then
  if [ "$HOST_HW_4K" -eq 1 ]; then BENCH_PROFILE=ultra
  elif [ "$HOST_HW_1440" -eq 1 ]; then BENCH_PROFILE=high
  elif [ "$MEM_MB" -ge 1800 ]; then BENCH_PROFILE=balanced
  fi
fi

log "base=${BENCH_FPS}fps eff=${EFF_FPS} steal=${STEAL_PCT}% mem=${MEM_MB}MB cpu=${CPU_N} hw=${HOST_HW_OK} 1440=${HOST_HW_1440}/${CPU_1440_SPEED}x 4k=${HOST_HW_4K}/${CPU_4K_SPEED}x -> $BENCH_PROFILE"

{
  echo "HOST_BENCH_FPS=$BENCH_FPS"
  echo "HOST_BENCH_EFF_FPS=$EFF_FPS"
  echo "HOST_STEAL_PCT=$STEAL_PCT"
  echo "HOST_BENCH_PROFILE=$BENCH_PROFILE"
  echo "HOST_HW_OK=$HOST_HW_OK"
  echo "HOST_HW_1440=$HOST_HW_1440"
  echo "HOST_HW_4K=$HOST_HW_4K"
  echo "HOST_CPU_1440_SPEED=$CPU_1440_SPEED"
  echo "HOST_CPU_4K_SPEED=$CPU_4K_SPEED"
  echo "HOST_MEM_MB=$MEM_MB"
  echo "HOST_CPU_N=$CPU_N"
  echo "HOST_VIRT=${HOST_VIRT:-unknown}"
  echo "HOST_CC=${HOST_CC:-none}"
  echo "HOST_BENCH_TIME=$(date +%s)"
} > "$ENV_OUT"
