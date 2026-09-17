#!/bin/bash
# ==============================================================================
# Quran Live Stream — First-Boot Orchestrator
# deps -> browser -> host tuning -> network probe -> encode benchmark -> cache -> service
# ==============================================================================
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"; cd "$BASE_DIR"
FORCE="${1:-}"
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] [FIRSTBOOT] $*"; }

log "=== Quran first-boot adaptation started ==="
if [ -z "${BASH_VERSION:-}" ]; then log "ERROR: bash 4+ required."; exit 1; fi
chmod 600 "$BASE_DIR/.env" 2>/dev/null || true
eval "$("$BASE_DIR/scripts/detect_host.sh")" || true
log "Host: virt=${HOST_VIRT:-?} cc=${HOST_CC:-none} mem=${HOST_MEM_MB:-?}MB cpu=${HOST_CPU_N:-?} disk=${HOST_DISK_AVAIL_MB:-?}MB gpu(nv=${HOST_HW_NVENC:-0},vaapi=${HOST_HW_VAAPI:-0},qsv=${HOST_HW_QSV:-0})"

log "--- [1/7] dependencies ---"
"$BASE_DIR/scripts/install_deps.sh" >>"$BASE_DIR/logs/install_deps.log" 2>&1 || log "WARNING: dependency install had failures."
log "--- [2/7] browser ---"
"$BASE_DIR/scripts/install_browser.sh" >>"$BASE_DIR/logs/install_browser.log" 2>&1 || log "WARNING: browser install had failures."
log "--- [3/7] provisioning (swap/zram/sysctl/services) ---"
"$BASE_DIR/scripts/tune_system.sh" $FORCE >>"$BASE_DIR/logs/tune_system.log" 2>&1 || log "WARNING: provisioning had failures."
log "--- [4/7] egress probe ---"
"$BASE_DIR/scripts/probe_egress.sh" $FORCE || log "WARNING: egress probe failed; runtime guard will have no measured ceiling."
log "--- [5/7] encode benchmark ---"
"$BASE_DIR/scripts/benchmark_host.sh" $FORCE || log "WARNING: benchmark failed; conservative hardware detection will be used."
log "--- [6/7] static/audio primer ---"
"$BASE_DIR/scripts/prime_static_cache.sh" >>"$BASE_DIR/logs/prime_static.log" 2>&1 || log "WARNING: primer failed."
log "--- [7/7] universal systemd user service ---"
"$BASE_DIR/scripts/install_service.sh" || log "WARNING: systemd user service install failed; direct script execution remains possible."

log "=== Decision summary ==="
if [ -f "$BASE_DIR/runtime/host.env" ]; then
  source "$BASE_DIR/runtime/host.env"
  log "Suggested ceiling: ${HOST_BENCH_PROFILE:-auto} (bench ${HOST_BENCH_EFF_FPS:-?}fps eff, steal ${HOST_STEAL_PCT:-?}%)"
else log "No benchmark result: hardware auto-detect applies."; fi
if [ -f "$BASE_DIR/runtime/net.env" ]; then
  source "$BASE_DIR/runtime/net.env"
  log "Uplink safe ceiling: ${HOST_EGRESS_SAFE_MBPS:-unknown} Mbps total."
fi
"$BASE_DIR/scripts/hardware_profile.sh" --show 2>/dev/null | tail -n 8 || true
log "=== first-boot done. Start: scripts/control.sh start ==="
