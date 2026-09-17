#!/bin/bash
set -u
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$BASE_DIR/runtime"

kill_pidfile() {
  local p="$1" pid
  [ -f "$p" ] || return 0
  pid="$(cat "$p" 2>/dev/null || true)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  # Grace first; SIGKILL only if the process did not exit.
  for _ in 1 2 3 4 5; do
    [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null && break
    sleep .2
  done
  [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
  rm -f "$p"
}

# Legacy single-canvas pid files.
kill_pidfile "$RUNTIME/quran-chrome.pid"
kill_pidfile "$RUNTIME/quran-xvfb.pid"

# Universal native multi-layout canvases.
for d in "$RUNTIME"/groups/*; do
  [ -d "$d" ] || continue
  kill_pidfile "$d/chrome.pid"
  kill_pidfile "$d/xvfb.pid"
done

# Shared web server is stopped last so browser shutdown never races its requests.
kill_pidfile "$RUNTIME/quran-web.pid"

# Kill only this project's local URL/profile processes if pid files became stale.
PORT="${QURAN_WEB_PORT:-4177}"
pkill -f "chrome.*127.0.0.1:${PORT}" 2>/dev/null || true
pkill -f "chromium.*127.0.0.1:${PORT}" 2>/dev/null || true

# Free the configured web port if a stale server survived.
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
elif command -v ss >/dev/null 2>&1; then
  for pid in $(ss -ltnp 2>/dev/null | grep ":${PORT} " | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p'); do
    kill "$pid" 2>/dev/null || true
  done
fi

for _ in $(seq 1 10); do
  (echo > "/dev/tcp/127.0.0.1/$PORT") >/dev/null 2>&1 || break
  sleep .2
done
