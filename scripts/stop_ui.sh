#!/bin/bash
set -u
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$BASE_DIR/runtime"
PORT="${QURAN_WEB_PORT:-4177}"
source "$BASE_DIR/scripts/process_guard.sh"

# Universal native multi-layout canvases. ui.env supplies the display identity
# needed to prove an Xvfb PID still belongs to this project before signalling it.
for d in "$RUNTIME"/groups/*; do
  [ -d "$d" ] || continue
  display=""
  if [ -f "$d/ui.env" ]; then
    display="$(sed -n 's/^DISPLAY=//p' "$d/ui.env" | head -1 | tr -cd '0-9')"
  fi
  quran_kill_pidfile "$d/chrome.pid" browser "$d"
  if [ -n "$display" ]; then
    quran_kill_pidfile "$d/xvfb.pid" xvfb "$display"
  else
    rm -f "$d/xvfb.pid"
  fi
done

# Shared web server is stopped last so browser shutdown never races its requests.
quran_kill_pidfile "$RUNTIME/quran-web.pid" web

# Clean up only orphaned project browser processes whose command line still
# carries this repository's group profile path. Never match browsers merely by
# localhost URL, since a user's manual preview may use the same port.
if command -v pgrep >/dev/null 2>&1; then
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    quran_stop_owned_pid "$pid" project-browser "" || true
  done < <(pgrep -f 'chrome|chromium' 2>/dev/null || true)
fi

# If a stale project Node process survived without its pidfile, identify it from
# the listening PID and kill it only after proving the command line is ours.
if command -v ss >/dev/null 2>&1; then
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    quran_stop_owned_pid "$pid" web "" || true
  done < <(ss -ltnp 2>/dev/null | grep ":${PORT} " | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u)
fi

for _ in $(seq 1 10); do
  (echo > "/dev/tcp/127.0.0.1/$PORT") >/dev/null 2>&1 || break
  sleep .2
done
