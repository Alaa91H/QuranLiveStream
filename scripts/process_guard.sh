#!/usr/bin/env bash
# Shared process-ownership guards for stale pidfiles and PID reuse.
# Callers define BASE_DIR and RUNTIME before sourcing this file.

quran_pid_cmdline() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [ -r "/proc/$pid/cmdline" ] || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null
}

quran_pid_comm() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [ -r "/proc/$pid/comm" ] || return 1
  tr -d '[:space:]' < "/proc/$pid/comm" 2>/dev/null
}

quran_owned_pid() {
  local pid="${1:-}" kind="${2:-}" marker="${3:-}" comm cmd
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  comm="$(quran_pid_comm "$pid" || true)"
  cmd="$(quran_pid_cmdline "$pid" || true)"

  case "$kind" in
    browser)
      case "$comm" in chrome|chromium|chromium-browse|google-chrome*) ;; *) return 1;; esac
      [ -n "$marker" ] || return 1
      [[ "$cmd" == *"--user-data-dir=$marker/chrome-profile"* ]]
      ;;
    project-browser)
      case "$comm" in chrome|chromium|chromium-browse|google-chrome*) ;; *) return 1;; esac
      [[ "$cmd" == *"--user-data-dir=$RUNTIME/groups/"*"/chrome-profile"* ]]
      ;;
    xvfb)
      [ "$comm" = "Xvfb" ] || return 1
      [ -n "$marker" ] || return 1
      # Match the display as a full argv token: :90 must not match :900.
      [[ " $cmd " == *" :$marker "* ]]
      ;;
    web)
      [ "$comm" = "node" ] || return 1
      [[ "$cmd" == *"$BASE_DIR/web/playback-hook.js"* && " $cmd " == *" server.js "* ]]
      ;;
    ffmpeg)
      [ "$comm" = "ffmpeg" ] || return 1
      [ -n "$marker" ] || return 1
      # Every managed worker includes its private -progress path in argv.
      [[ " $cmd " == *" -progress $marker "* ]]
      ;;
    *) return 1 ;;
  esac
}

quran_stop_owned_pid() {
  local pid="${1:-}" kind="${2:-}" marker="${3:-}"
  quran_owned_pid "$pid" "$kind" "$marker" || return 1
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep .2
  done
  quran_owned_pid "$pid" "$kind" "$marker" && kill -9 "$pid" 2>/dev/null || true
  return 0
}

quran_kill_pidfile() {
  local file="${1:-}" kind="${2:-}" marker="${3:-}" pid
  [ -f "$file" ] || return 0
  pid="$(cat "$file" 2>/dev/null || true)"
  quran_stop_owned_pid "$pid" "$kind" "$marker" || true
  rm -f "$file"
}
