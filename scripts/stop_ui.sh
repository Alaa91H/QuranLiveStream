#!/bin/bash
set -u
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$BASE_DIR/runtime"
PORT="${QURAN_WEB_PORT:-4177}"

pid_cmdline() {
  local pid="$1"
  [ -r "/proc/$pid/cmdline" ] || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null
}

pid_comm() {
  local pid="$1"
  [ -r "/proc/$pid/comm" ] || return 1
  tr -d '[:space:]' < "/proc/$pid/comm" 2>/dev/null
}

owned_pid() {
  local pid="$1" kind="$2" marker="${3:-}" comm cmd
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  comm="$(pid_comm "$pid" || true)"
  cmd="$(pid_cmdline "$pid" || true)"
  case "$kind" in
    browser)
      case "$comm" in chrome|chromium|chromium-browser|google-chrome*) ;; *) return 1;; esac
      [ -n "$marker" ] && [[ "$cmd" == *"--user-data-dir=$marker/chrome-profile"* ]]
      ;;
    project-browser)
      case "$comm" in chrome|chromium|chromium-browser|google-chrome*) ;; *) return 1;; esac
      [[ "$cmd" == *"--user-data-dir=$RUNTIME/groups/"*"/chrome-profile"* ]]
      ;;
    xvfb)
      [ "$comm" = "Xvfb" ] || return 1
      [ -n "$marker" ] && [[ "$cmd" == *":$marker"* ]]
      ;;
    web)
      [ "$comm" = "node" ] || return 1
      [[ "$cmd" == *"$BASE_DIR/web/playback-hook.js"* && "$cmd" == *"server.js"* ]]
      ;;
    *) return 1 ;;
  esac
}

stop_owned_pid() {
  local pid="$1" kind="$2" marker="${3:-}"
  owned_pid "$pid" "$kind" "$marker" || return 1
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep .2
  done
  owned_pid "$pid" "$kind" "$marker" && kill -9 "$pid" 2>/dev/null || true
  return 0
}

kill_pidfile() {
  local file="$1" kind="$2" marker="${3:-}" pid
  [ -f "$file" ] || return 0
  pid="$(cat "$file" 2>/dev/null || true)"
  if ! stop_owned_pid "$pid" "$kind" "$marker"; then
    # A stale/reused PID must never authorize killing an unrelated process.
    :
  fi
  rm -f "$file"
}

# Universal native multi-layout canvases. ui.env supplies the display identity
# needed to prove an Xvfb PID still belongs to this project before signalling it.
for d in "$RUNTIME"/groups/*; do
  [ -d "$d" ] || continue
  display=""
  if [ -f "$d/ui.env" ]; then
    display="$(sed -n 's/^DISPLAY=//p' "$d/ui.env" | head -1 | tr -cd '0-9')"
  fi
  kill_pidfile "$d/chrome.pid" browser "$d"
  [ -n "$display" ] && kill_pidfile "$d/xvfb.pid" xvfb "$display" || rm -f "$d/xvfb.pid"
done

# Shared web server is stopped last so browser shutdown never races its requests.
kill_pidfile "$RUNTIME/quran-web.pid" web

# Clean up only orphaned project browser processes whose command line still
# carries this repository's group profile path. Never match browsers merely by
# localhost URL, since a user's manual preview may use the same port.
if command -v pgrep >/dev/null 2>&1; then
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    stop_owned_pid "$pid" project-browser "" || true
  done < <(pgrep -f 'chrome|chromium' 2>/dev/null || true)
fi

# If a stale project Node process survived without its pidfile, identify it from
# the listening PID and kill it only after proving the command line is ours.
if command -v ss >/dev/null 2>&1; then
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    stop_owned_pid "$pid" web "" || true
  done < <(ss -ltnp 2>/dev/null | grep ":${PORT} " | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u)
fi

for _ in $(seq 1 10); do
  (echo > "/dev/tcp/127.0.0.1/$PORT") >/dev/null 2>&1 || break
  sleep .2
done
