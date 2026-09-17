#!/usr/bin/env bash
set -Eeuo pipefail
BASE="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="quran-live.service"

ensure_service(){
  if ! systemctl --user cat "$SERVICE" >/dev/null 2>&1; then
    "$BASE/scripts/install_service.sh"
  fi
}

case "${1:-}" in
  start)
    ensure_service
    rm -f "$BASE/runtime/broadcast_stopped.flag"
    systemctl --user daemon-reload
    systemctl --user start "$SERVICE"
    systemctl --user status "$SERVICE" --no-pager | head -n 60
    ;;
  stop)
    echo "Stopping stream..."
    mkdir -p "$BASE/runtime"
    touch "$BASE/runtime/broadcast_stopped.flag"
    systemctl --user stop "$SERVICE" 2>/dev/null || true
    "$BASE/scripts/stop_ui.sh" >/dev/null 2>&1 || true
    echo "Stopped."
    ;;
  restart)
    ensure_service
    rm -f "$BASE/runtime/broadcast_stopped.flag"
    systemctl --user restart "$SERVICE"
    systemctl --user status "$SERVICE" --no-pager | head -n 60
    ;;
  status)
    ensure_service
    systemctl --user status "$SERVICE" --no-pager 2>&1 | head -n 80 || true
    echo "--- adaptive telemetry ---"
    cat "$BASE/runtime/load.status" 2>/dev/null || echo "No telemetry yet."
    echo "--- selected targets ---"
    grep -E '^STREAM_TARGETS=' "$BASE/.env" 2>/dev/null || echo "STREAM_TARGETS=yellow default: youtube"
    echo "--- ffmpeg ---"
    ps -eo pid,pcpu,pmem,args | grep '[f]fmpeg' || echo "No ffmpeg process."
    ;;
  logs)
    touch "$BASE/logs/stream_universal.log"
    tail -f "$BASE/logs/stream_universal.log"
    ;;
  enable)
    ensure_service
    systemctl --user enable "$SERVICE"
    systemctl --user start "$SERVICE"
    echo "Autostart enabled."
    ;;
  disable)
    systemctl --user disable "$SERVICE" 2>/dev/null || true
    echo "Autostart disabled."
    ;;
  prepare)
    echo "Preparing host (dependencies/cache/benchmark/network/preflight)..."
    "$BASE/scripts/first_boot.sh" --force
    "$BASE/scripts/install_service.sh"
    "$BASE/scripts/preflight.sh"
    echo "Preparation complete."
    ;;
  preflight)
    "$BASE/scripts/preflight.sh"
    ;;
  targets)
    echo "Configured platform list:"
    grep -E '^STREAM_TARGETS=' "$BASE/.env" 2>/dev/null || echo "STREAM_TARGETS=youtube"
    echo "Any slug is supported when SLUG_RTMP_URL and SLUG_STREAM_KEY are defined."
    ;;
  reset-adaptive)
    rm -f "$BASE/runtime/adaptive_rank" "$BASE/runtime/load.status"
    echo "Adaptive state reset; next restart begins from hardware/benchmark profile."
    ;;
  *)
    cat <<EOF
Usage: $0 {start|stop|restart|status|logs|enable|disable|prepare|preflight|targets|reset-adaptive}

The enabled platforms are controlled only by .env, for example:
  STREAM_TARGETS=youtube,tiktok,facebook

Custom platform example:
  STREAM_TARGETS=youtube,myplatform
  MYPLATFORM_RTMP_URL=rtmps://ingest.example.com/live
  MYPLATFORM_STREAM_KEY=secret
EOF
    ;;
esac
