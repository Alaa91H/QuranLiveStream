#!/usr/bin/env bash
# QuranLiveStream universal control panel.
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$BASE_DIR/runtime"; LOGS="$BASE_DIR/logs"
mkdir -p "$RUNTIME" "$LOGS"
source "$BASE_DIR/scripts/platforms.sh"

ensure_units() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local dir="$HOME/.config/systemd/user" escaped cores quota
  mkdir -p "$dir"
  escaped="${BASE_DIR//|/\\|}"
  cores="$(nproc 2>/dev/null || echo 1)"; case "$cores" in ''|*[!0-9]*) cores=1;; esac
  # 90% of the host's aggregate CPU capacity (1 core=90%, 4 cores=360%).
  # Runtime governor normally stays below this; cgroup quota is the final guard.
  quota=$((cores * ${SYSTEMD_CPU_HARD_PCT:-90}))
  sed -e "s|@QURAN_HOME@|$escaped|g" -e "s|@CPU_QUOTA@|${quota}%|g" \
    "$BASE_DIR/systemd/quran-live.service" > "$dir/quran-live.service"
  sed "s|@QURAN_HOME@|$escaped|g" "$BASE_DIR/systemd/quran-live-governor.service" > "$dir/quran-live-governor.service"
  chmod +x "$BASE_DIR"/scripts/*.sh 2>/dev/null || true
  systemctl --user daemon-reload
  if command -v loginctl >/dev/null 2>&1; then loginctl enable-linger "$USER" >/dev/null 2>&1 || true; fi
}

select_targets() {
  local raw="${1:-}" t clean=""
  [ -n "$raw" ] || { echo "ERROR: provide comma-separated targets, e.g. youtube,tiktok" >&2; return 1; }
  STREAM_TARGETS="$raw"; export STREAM_TARGETS
  while IFS= read -r t; do
    quran_target_valid_name "$t" || { echo "ERROR: invalid target '$t'" >&2; return 1; }
    clean="${clean}${clean:+,}$t"
  done < <(quran_targets_lines)
  [ -n "$clean" ] || return 1
  printf 'STREAM_TARGETS=%q\n' "$clean" > "$RUNTIME/targets.env"
  echo "Selected platforms: $clean"
}

show_targets() {
  [ -f "$BASE_DIR/.env" ] && { set -a; source "$BASE_DIR/.env" 2>/dev/null; set +a; } || true
  quran_targets_load
  echo "Selected: $STREAM_TARGETS"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if quran_target_uri "$t" >/dev/null 2>&1; then
      echo "  ✓ $(quran_target_redacted "$t") | layout=$(quran_target_layout "$t") | max=$(quran_target_max_profile "$t")"
    else
      echo "  ✗ $t missing credentials"
    fi
  done < <(quran_targets_lines)
}

cmd="${1:-help}"
case "$cmd" in
  select)
    select_targets "${2:-}"
    ;;
  start)
    [ -n "${2:-}" ] && select_targets "$2"
    ensure_units
    # Legacy platform-specific services must never run beside the coordinated engine.
    systemctl --user stop quran-live-youtube.service quran-live-tiktok.service 2>/dev/null || true
    systemctl --user disable quran-live-youtube.service quran-live-tiktok.service 2>/dev/null || true
    rm -f "$RUNTIME/broadcast_stopped.flag"
    systemctl --user enable --now quran-live-governor.service >/dev/null 2>&1 || true
    systemctl --user restart quran-live.service
    sleep 1
    systemctl --user status quran-live.service --no-pager -l | head -n 35 || true
    ;;
  stop)
    touch "$RUNTIME/broadcast_stopped.flag"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl --user stop quran-live.service quran-live-youtube.service quran-live-tiktok.service 2>/dev/null || true
    fi
    "$BASE_DIR/scripts/stop_ui.sh" >/dev/null 2>&1 || true
    rm -f "$RUNTIME/stream_active.flag"
    echo "✓ broadcast stopped (resource governor remains idle)"
    ;;
  restart)
    "$0" stop; sleep 2; if [ -n "${2:-}" ]; then "$0" start "$2"; else "$0" start; fi
    ;;
  status)
    ensure_units
    systemctl --user status quran-live.service quran-live-governor.service --no-pager -l 2>&1 | head -n 70 || true
    echo "--- selected targets ---"; show_targets
    echo "--- active ---"; cat "$RUNTIME/active_profile.env" 2>/dev/null || echo "inactive"
    echo "--- current stream plan ---"; cat "$RUNTIME/stream_plan.txt" 2>/dev/null || echo "no plan yet"
    echo "--- resources ---"; cat "$RUNTIME/resources.json" 2>/dev/null || echo "no governor sample yet"
    echo "--- group workers ---"
    for f in "$RUNTIME"/groups/*/worker.env; do [ -f "$f" ] && { echo "[$(basename "$(dirname "$f")")]"; cat "$f"; }; done
    echo "--- ffmpeg ---"; pgrep -af ffmpeg || echo "no ffmpeg"
    ;;
  logs)
    case "${2:-stream}" in
      governor|resources) tail -f "$LOGS/resource_governor.log" ;;
      g*) tail -f "$LOGS/stream_${2}.log" ;;
      *) tail -f "$LOGS/stream.log" ;;
    esac
    ;;
  enable)
    ensure_units
    systemctl --user enable quran-live.service quran-live-governor.service
    echo "✓ auto-start enabled"
    ;;
  disable)
    ensure_units
    systemctl --user disable quran-live.service quran-live-governor.service
    echo "✓ auto-start disabled"
    ;;
  prepare)
    echo "Preparing host: tuning + cache + benchmark + egress + preflight..."
    "$BASE_DIR/scripts/tune_system.sh" || true
    "$BASE_DIR/scripts/prime_static_cache.sh" || true
    "$BASE_DIR/scripts/benchmark_host.sh" --force || true
    "$BASE_DIR/scripts/probe_egress.sh" --force || true
    "$BASE_DIR/scripts/preflight.sh"
    echo "✓ preparation complete"
    ;;
  preflight)
    "$BASE_DIR/scripts/preflight.sh"
    ;;
  plan)
    "$BASE_DIR/scripts/stream_plan.sh"
    ;;
  targets|platforms)
    show_targets
    ;;
  governor-reset|reset-tuning)
    rm -f "$RUNTIME/governor.env" "$RUNTIME/governor.state"
    echo "✓ live governor overrides cleared; next start uses measured benchmark ceiling"
    ;;
  install-units)
    ensure_units; echo "✓ systemd user units installed for $BASE_DIR"
    ;;
  *)
    cat <<USAGE
Usage:
  $0 select youtube,tiktok,facebook
  $0 start [youtube,tiktok,...]   # publishes ONLY selected platforms
  $0 stop | restart | status
  $0 targets                     # selected/configured targets + native layouts
  $0 plan                        # show adaptive native-canvas plan without starting
  $0 logs [stream|governor|g0|g1...]
  $0 prepare | preflight
  $0 enable | disable
  $0 reset-tuning

Any RTMP/RTMPS platform can be added in .env using NAME_RTMP_TARGET, or
NAME_RTMP_URL + NAME_STREAM_KEY, then selected with: $0 start name
Per-platform overrides: NAME_LAYOUT, NAME_MAX_PROFILE, NAME_MAX_FPS,
NAME_MAX_VIDEO_BITRATE, NAME_VIDEO_CODEC.
USAGE
    ;;
esac
