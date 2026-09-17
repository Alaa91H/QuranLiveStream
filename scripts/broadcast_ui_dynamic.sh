#!/usr/bin/env bash
# Headless UI launcher used by the universal broadcaster.
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$BASE_DIR/runtime"; LOG_DIR="$BASE_DIR/logs"
mkdir -p "$RUNTIME" "$LOG_DIR"
source "$BASE_DIR/scripts/hardware_profile.sh"
if [ "${STREAM_LAYOUT_RESOLVED:-landscape}" = "portrait" ]; then
  tmp="$STREAM_WIDTH"; STREAM_WIDTH="$STREAM_HEIGHT"; STREAM_HEIGHT="$tmp"
fi
if [ -f "$RUNTIME/governor.env" ]; then
  source "$RUNTIME/governor.env" 2>/dev/null || true
fi
PORT="${QURAN_WEB_PORT:-4177}"; DISPLAY_NUM="${QURAN_DISPLAY:-99}"
PIDFILE="$RUNTIME/quran-web.pid"; XVFB_PIDFILE="$RUNTIME/quran-xvfb.pid"; CHROME_PIDFILE="$RUNTIME/quran-chrome.pid"

if [ "${PRIME_STATIC:-1}" != "0" ]; then
  "$BASE_DIR/scripts/prime_static_cache.sh" --light-only >>"$LOG_DIR/prime_static.log" 2>&1 || true
fi

if [ "${AUDIO_MODE:-pulse}" != "file" ] && command -v pactl >/dev/null 2>&1; then
  if ! pactl info >/dev/null 2>&1; then pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true; sleep 1; fi
  pactl load-module module-null-sink sink_name=quran_sink sink_properties=device.description="QuranSink" >/dev/null 2>&1 || true
fi

if ! kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  echo "[$(date '+%F %T')] Starting web server (Node max ${NODE_MEM_MB}MB)..."
  (cd "$BASE_DIR/web" && PORT="$PORT" node --max-old-space-size="${NODE_MEM_MB}" server.js >>"$LOG_DIR/web.log" 2>&1 & echo $! >"$PIDFILE")
  for _ in $(seq 1 25); do
    curl -s --max-time 2 "http://127.0.0.1:$PORT/api/health" 2>/dev/null | grep -q '"ok":true' && break
    sleep 1
  done
fi

X_SIG="${STREAM_WIDTH}x${STREAM_HEIGHT}"
if [ "$(cat "$RUNTIME/xvfb-geometry.sig" 2>/dev/null)" != "$X_SIG" ]; then
  kill "$(cat "$XVFB_PIDFILE" 2>/dev/null)" 2>/dev/null || true
  kill "$(cat "$CHROME_PIDFILE" 2>/dev/null)" 2>/dev/null || true
  rm -f "$XVFB_PIDFILE" "$CHROME_PIDFILE"
fi
if ! kill -0 "$(cat "$XVFB_PIDFILE" 2>/dev/null)" 2>/dev/null; then
  echo "[$(date '+%F %T')] Starting Xvfb :$DISPLAY_NUM ${X_SIG}x24..."
  Xvfb ":$DISPLAY_NUM" -screen 0 "${STREAM_WIDTH}x${STREAM_HEIGHT}x24" -nolisten tcp >"$LOG_DIR/xvfb.log" 2>&1 & echo $! >"$XVFB_PIDFILE"
  echo "$X_SIG" > "$RUNTIME/xvfb-geometry.sig"
  sleep 1
fi

want_audio="audio=${AUDIO_MODE:-pulse}"
if kill -0 "$(cat "$CHROME_PIDFILE" 2>/dev/null)" 2>/dev/null && [ "$(cat "$RUNTIME/chrome-audio.sig" 2>/dev/null)" != "$want_audio" ]; then
  kill "$(cat "$CHROME_PIDFILE")" 2>/dev/null || true; rm -f "$CHROME_PIDFILE"
fi
if ! kill -0 "$(cat "$CHROME_PIDFILE" 2>/dev/null)" 2>/dev/null; then
  BROWSER_BIN="${CHROME_BIN:-}"
  [ -n "$BROWSER_BIN" ] || BROWSER_BIN="$(command -v google-chrome || command -v chromium-browser || command -v chromium || echo chromium)"
  CHROME_AUDIO_FLAGS=(); CHROME_SINK_ENV=""
  if [ "${AUDIO_MODE:-pulse}" = "file" ]; then CHROME_AUDIO_FLAGS=(--mute-audio --disable-audio-output); else CHROME_SINK_ENV="PULSE_SINK=quran_sink"; fi

  CITIES="${GOVERNOR_CITY_LIMIT:-}"
  LOWFX=0
  case "${PROFILE:-}" in nano) [ -n "$CITIES" ] || CITIES=2; LOWFX=1;; micro) [ -n "$CITIES" ] || CITIES=3; LOWFX=1;; esac
  APP_QUERY=""
  if [ "$LOWFX" = "1" ] || [ -n "$CITIES" ]; then
    APP_QUERY="?lowfx=${LOWFX}"
    [ -n "$CITIES" ] && APP_QUERY="${APP_QUERY}&cities=${CITIES}"
  fi

  TASKSET_PRE=()
  if [ -n "${TASKSET_CHROME:-}" ] && command -v taskset >/dev/null 2>&1; then TASKSET_PRE=(taskset -c "$TASKSET_CHROME"); fi
  echo "[$(date '+%F %T')] Starting browser ${STREAM_WIDTH}x${STREAM_HEIGHT}, profile=${PROFILE}, cities=${CITIES:-default}, lowfx=$LOWFX..."
  DISPLAY=":$DISPLAY_NUM" env $CHROME_SINK_ENV "${TASKSET_PRE[@]}" "$BROWSER_BIN" \
    --no-sandbox --disable-gpu --in-process-gpu --enable-low-end-device-mode --disable-dev-shm-usage \
    --renderer-process-limit=1 --disable-extensions --disable-background-networking --disable-sync --disable-default-apps \
    --no-first-run --no-default-browser-check --hide-crash-restore-bubble --noerrdialogs --disable-logging --log-level=3 \
    --disable-crash-reporter --no-crash-upload --disable-breakpad --disable-hang-monitor --disable-gpu-watchdog \
    --disable-client-side-phishing-detection --disable-domain-reliability --no-pings --disable-notifications \
    --block-new-web-contents --deny-permission-prompts --disable-component-update --disable-component-extensions-with-background-pages \
    --disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows \
    --aggressive-cache-discard --disk-cache-size=1048576 --media-cache-size=1048576 --password-store=basic \
    --force-color-profile=srgb --disable-lcd-text --hide-scrollbars --disable-smooth-scrolling \
    --autoplay-policy=no-user-gesture-required --allow-running-insecure-content --kiosk \
    --window-size="${STREAM_WIDTH},${STREAM_HEIGHT}" --window-position=0,0 \
    --js-flags="--max-old-space-size=${CHROME_MEM_MB} --optimize-for-size" \
    --disable-features=Translate,TranslateUI,MediaRouter,DialMediaRouteProvider,OptimizationHints,InterestFeedContentSuggestions,PrivacySandboxSettings4,AutofillServerCommunication,CertificateTransparencyComponentUpdater,GlobalMediaControls,HeavyAdPrivacyMitigations,CalculateNativeWinOcclusion,DestroyProfileOnBrowserClose,PaintHolding \
    "${CHROME_AUDIO_FLAGS[@]}" --app="http://127.0.0.1:$PORT/$APP_QUERY" >"$LOG_DIR/chromium.log" 2>&1 & echo $! >"$CHROME_PIDFILE"
  echo "$want_audio" > "$RUNTIME/chrome-audio.sig"
  sleep 3
fi

echo "[$(date '+%F %T')] Dynamic UI ready on DISPLAY=:$DISPLAY_NUM (${STREAM_WIDTH}x${STREAM_HEIGHT}, $PROFILE)."
