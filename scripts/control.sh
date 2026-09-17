#!/usr/bin/env bash
# QuranLiveStream universal control panel.
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$BASE_DIR/runtime"; LOGS="$BASE_DIR/logs"
mkdir -p "$RUNTIME" "$LOGS"
source "$BASE_DIR/scripts/platforms.sh"

ensure_units() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local dir="$HOME/.config/systemd/user" escaped
  mkdir -p "$dir"
  escaped="${BASE_DIR//|/\\|}"
  sed "s|@QURAN_HOME@|$escaped|g" "$BASE_DIR/systemd/quran-live.service" > "$dir/quran-live.service"
  sed "s|@QURAN_HOME@|$escaped|g" "$BASE_DIR/systemd/quran-live-governor.service" > "$dir/quran-live-governor.service"
  systemctl --user daemon-reload
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
  [ -f .env ] && { set -a; source .env 2>/dev/null; set +a; } || true
  quran_targets_load
  echo "Selected: $STREAM_TARGETS"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if quran_target_uri "$t" >/dev/null 2>&1; then echo "  ✓ $(quran_target_redacted "$t") configured"; else echo "  ✗ $t missing credentials"; fi
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
    if command -v systemctl >/dev/null 2>&1; then systemctl --user stop quran-live.service quran-live-youtube.service quran-live-tiktok.service 2>/dev/null || true; fi
    "$BASE_DIR/scripts/stop_ui.sh" >/dev/null 2>&1 || true
    rm -f "$RUNTIME/stream_active.flag"
    echo "✓ broadcast stopped (governor may remain idle)"
    ;;
  restart)
    "$0" stop; sleep 2; "$0" start "${2:-}"
    ;;
  status)
    ensure_units
    systemctl --user status quran-live.service quran-live-governor.service --no-pager -l 2>&1 | head -n 70 || true
    echo "--- selected targets ---"; show_targets
    echo "--- active profile ---"; cat "$RUNTIME/active_profile.env" 2>/dev/null || echo "inactive"
    echo "--- resources ---"; cat "$RUNTIME/resources.json" 2>/dev/null || echo "no governor sample yet"
    echo "--- ffmpeg ---"; pgrep -af ffmpeg || echo "no ffmpeg"
    ;;
  logs)
    case "${2:-stream}" in
      governor|resources) tail -f "$LOGS/resource_governor.log" ;;
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
    echo "Preparing host: dependencies/cache + benchmark + egress + preflight..."
    "$BASE_DIR/scripts/prime_static_cache.sh" || true
    "$BASE_DIR/scripts/benchmark_host.sh" --force || true
    "$BASE_DIR/scripts/probe_egress.sh" --force || true
    "$BASE_DIR/scripts/preflight.sh"
    echo "✓ preparation complete"
    ;;
  preflight)
    "$BASE_DIR/scripts/preflight.sh"
    ;;
  targets|platforms)
    show_targets
    ;;
  governor-reset|reset-tuning)
    rm -f "$RUNTIME/governor.env" "$RUNTIME/governor.state"
    echo "✓ live governor overrides cleared; next start uses benchmark profile"
    ;;
  install-units)
    ensure_units; echo "✓ systemd user units installed for $BASE_DIR"
    ;;
  *)
    cat <<USAGE
Usage:
  $0 select youtube,tiktok,facebook
  $0 start [youtube,tiktok,...]   # only selected platforms are published
  $0 stop | restart | status
  $0 targets                     # show selected/configured targets
  $0 logs [stream|governor]
  $0 prepare | preflight
  $0 enable | disable
  $0 reset-tuning

Any RTMP/RTMPS platform can be added in .env using NAME_RTMP_TARGET, or
NAME_RTMP_URL + NAME_STREAM_KEY, then selected with: $0 start name
USAGE
    ;;
esac
