#!/bin/bash
# ==============================================================================
# QuranLiveStream — first-boot adaptive host orchestrator
# deps -> browser -> swap/zram/sysctl -> egress -> progressive encode benchmark
# -> static cache -> portable systemd units. Idempotent and architecture-aware.
# ==============================================================================
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"; cd "$BASE_DIR"
FORCE="${1:-}"
log(){ echo "[$(date '+%F %T')] [FIRSTBOOT] $*"; }

log "=== first-boot adaptation started ==="
[ -n "${BASH_VERSION:-}" ] || { log "ERROR: bash required."; exit 1; }
chmod 600 "$BASE_DIR/.env" 2>/dev/null || true
mkdir -p "$BASE_DIR/logs" "$BASE_DIR/runtime"
eval "$("$BASE_DIR/scripts/detect_host.sh")" || true
log "Host: virt=${HOST_VIRT:-?} cc=${HOST_CC:-none} mem=${HOST_MEM_MB:-?}MB cpu=${HOST_CPU_N:-?} disk=${HOST_DISK_AVAIL_MB:-?}MB gpu(nv=${HOST_HW_NVENC:-0},vaapi=${HOST_HW_VAAPI:-0},qsv=${HOST_HW_QSV:-0})"

log "[1/7] dependencies"
"$BASE_DIR/scripts/install_deps.sh" >>"$BASE_DIR/logs/install_deps.log" 2>&1 || log "WARNING: dependency install had failures."
log "[2/7] browser"
"$BASE_DIR/scripts/install_browser.sh" >>"$BASE_DIR/logs/install_browser.log" 2>&1 || log "WARNING: browser setup had failures."
log "[3/7] host tuning (swap/zram/sysctl/services)"
"$BASE_DIR/scripts/tune_system.sh" $FORCE >>"$BASE_DIR/logs/tune_system.log" 2>&1 || log "WARNING: host tuning had failures."
log "[4/7] egress measurement"
"$BASE_DIR/scripts/probe_egress.sh" $FORCE || log "WARNING: egress probe failed; conservative fallback applies."
log "[5/7] progressive encode benchmark (higher tiers are tested only on capable hardware)"
"$BASE_DIR/scripts/benchmark_host.sh" $FORCE || log "WARNING: benchmark failed; hardware auto-detection fallback applies."
log "[6/7] static cache primer"
"$BASE_DIR/scripts/prime_static_cache.sh" >>"$BASE_DIR/logs/prime_static.log" 2>&1 || log "WARNING: static primer had failures."
log "[7/7] universal user-systemd units"
"$BASE_DIR/scripts/control.sh" install-units >/dev/null 2>&1 || log "WARNING: user systemd units could not be installed yet."

log "=== decision summary ==="
if [ -f "$BASE_DIR/runtime/host.env" ]; then
  source "$BASE_DIR/runtime/host.env"
  log "Profile ceiling: ${HOST_BENCH_PROFILE:-auto} | base eff=${HOST_BENCH_EFF_FPS:-?}fps steal=${HOST_STEAL_PCT:-?}% | hw=${HOST_HW_OK:-cpu} 1440=${HOST_HW_1440:-0} 4K=${HOST_HW_4K:-0}"
else
  log "No benchmark file; conservative hardware auto-detection applies."
fi
if [ -f "$BASE_DIR/runtime/net.env" ]; then
  source "$BASE_DIR/runtime/net.env"
  log "Safe uplink ceiling: ${HOST_EGRESS_SAFE_MBPS:-unknown} Mbps"
fi
log "=== first-boot complete. Configure .env then run: scripts/control.sh preflight && scripts/control.sh start ==="
