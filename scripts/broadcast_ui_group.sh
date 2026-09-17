#!/usr/bin/env bash
# ==============================================================================
# QuranLiveStream — one native browser canvas per aspect/quality group
# Usage: broadcast_ui_group.sh GROUP LAYOUT PROFILE DISPLAY
# ==============================================================================
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GROUP="${1:?group}"; LAYOUT="${2:?layout}"; PROFILE_REQ="${3:?profile}"; DISPLAY_NUM="${4:?display}"
cd "$BASE_DIR"
[ -f .env ] && { set -a; source .env 2>/dev/null; set +a; } || true
source "$BASE_DIR/scripts/platforms.sh"
STREAM_PROFILE="$PROFILE_REQ"; export STREAM_PROFILE
source "$BASE_DIR/scripts/hardware_profile.sh"
read -r STREAM_WIDTH STREAM_HEIGHT < <(quran_profile_dimensions "$PROFILE_REQ" "$LAYOUT")
export STREAM_WIDTH STREAM_HEIGHT

PORT="${QURAN_WEB_PORT:-4177}"; RUNTIME="$BASE_DIR/runtime"; LOG_DIR="$BASE_DIR/logs"
GR="$RUNTIME/groups/$GROUP"; mkdir -p "$GR" "$LOG_DIR"
source "$BASE_DIR/scripts/process_guard.sh"
WEB_PID="$RUNTIME/quran-web.pid"; XVFB_PID="$GR/xvfb.pid"; CHROME_PID="$GR/chrome.pid"
SIG="$STREAM_WIDTH:$STREAM_HEIGHT:$LAYOUT:$PROFILE_REQ:${GROUP_AUDIO_MASTER:-0}"
web_healthy(){ curl -fsS --max-time 2 "http://127.0.0.1:$PORT/api/health" 2>/dev/null | grep -q '"ok":true'; }

# One shared Node server for all canvases. flock prevents a multi-worker race.
# Health, not merely PID existence, decides whether the server is reusable.
(
  flock -x 9
  if ! web_healthy; then
    oldpid="$(cat "$WEB_PID" 2>/dev/null || true)"
    if quran_owned_pid "$oldpid" web ""; then
      echo "[$(date '+%F %T')] web PID $oldpid is alive but unhealthy; restarting." >>"$LOG_DIR/web.log"
      quran_stop_owned_pid "$oldpid" web "" || true
    fi
    rm -f "$WEB_PID"

    # Refuse to hide a foreign/stuck listener behind a blank browser capture.
    if (echo > /dev/tcp/127.0.0.1/$PORT) >/dev/null 2>&1; then
      echo "[$(date '+%F %T')] ERROR port $PORT is occupied by an unhealthy process." >>"$LOG_DIR/web.log"
      exit 1
    fi

    (cd "$BASE_DIR/web" && PORT="$PORT" node --require "$BASE_DIR/web/playback-hook.js" --max-old-space-size="${NODE_MEM_MB}" server.js >>"$LOG_DIR/web.log" 2>&1 & echo $! >"$WEB_PID")
    ready=0
    for _ in $(seq 1 30); do
      if web_healthy; then ready=1; break; fi
      sleep 1
    done
    if [ "$ready" -ne 1 ]; then
      badpid="$(cat "$WEB_PID" 2>/dev/null || true)"
      quran_stop_owned_pid "$badpid" web "" || true
      rm -f "$WEB_PID"
      echo "[$(date '+%F %T')] ERROR Quran web API failed to become healthy on port $PORT." >>"$LOG_DIR/web.log"
      exit 1
    fi
  fi
) 9>"$RUNTIME/web.lock" || exit 1

# One browser (group0) is the recitation master. It emits browser audio into a
# single null sink; all FFmpeg workers read that monitor. Follower canvases are
# muted and mirror the master's verse through the local playback API.
if [ "${GROUP_AUDIO_MASTER:-0}" = "1" ] && command -v pactl >/dev/null 2>&1; then
  if ! pactl info >/dev/null 2>&1; then pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || true; sleep 1; fi
  pactl list short sinks 2>/dev/null | grep -q '[[:space:]]quran_sink[[:space:]]' || pactl load-module module-null-sink sink_name=quran_sink sink_properties=device.description=QuranSink >/dev/null 2>&1 || true
fi

# Geometry/profile/master change => recreate this group's native X/Chrome canvas.
if [ "$(cat "$GR/signature" 2>/dev/null)" != "$SIG" ]; then
  quran_stop_owned_pid "$(cat "$CHROME_PID" 2>/dev/null || true)" browser "$GR" || true
  quran_stop_owned_pid "$(cat "$XVFB_PID" 2>/dev/null || true)" xvfb "$DISPLAY_NUM" || true
  rm -f "$CHROME_PID" "$XVFB_PID"
  sleep .5
fi

xpid="$(cat "$XVFB_PID" 2>/dev/null || true)"
if ! quran_owned_pid "$xpid" xvfb "$DISPLAY_NUM"; then
  rm -f "$XVFB_PID"
  Xvfb ":$DISPLAY_NUM" -screen 0 "${STREAM_WIDTH}x${STREAM_HEIGHT}x24" -nolisten tcp >"$LOG_DIR/xvfb_${GROUP}.log" 2>&1 &
  echo $! > "$XVFB_PID"; sleep 1
fi

cpid="$(cat "$CHROME_PID" 2>/dev/null || true)"
if ! quran_owned_pid "$cpid" browser "$GR"; then
  rm -f "$CHROME_PID"
  BROWSER_BIN="${CHROME_BIN:-}"
  [ -n "$BROWSER_BIN" ] || BROWSER_BIN="$(command -v google-chrome || command -v chromium-browser || command -v chromium || echo chromium)"
  CITIES="${GOVERNOR_CITY_LIMIT:-$(quran_layout_default_cities "$LAYOUT" "$PROFILE_REQ")}"; LOWFX=0
  case "$PROFILE_REQ" in nano|micro) LOWFX=1;; esac
  MASTER="${GROUP_AUDIO_MASTER:-0}"
  QUERY="layout=$LAYOUT&profile=$PROFILE_REQ&group=$GROUP&cities=$CITIES&lowfx=$LOWFX&master=$MASTER"

  CHROME_AUDIO=(); SINK_ENV=()
  if [ "$MASTER" != "1" ]; then
    CHROME_AUDIO=(--mute-audio --disable-audio-output)
  else
    SINK_ENV=(PULSE_SINK=quran_sink)
  fi

  GROUPS="${STREAM_GROUP_COUNT:-1}"; MEM="$CHROME_MEM_MB"
  if [[ "$GROUPS" =~ ^[0-9]+$ ]] && [ "$GROUPS" -gt 1 ]; then
    MEM=$((CHROME_MEM_MB / GROUPS + 64)); [ "$MEM" -lt 96 ] && MEM=96
  fi

  TASKSET_PRE=()
  if [ -n "${TASKSET_CHROME:-}" ] && command -v taskset >/dev/null 2>&1; then TASKSET_PRE=(taskset -c "$TASKSET_CHROME"); fi

  DISPLAY=":$DISPLAY_NUM" env "${SINK_ENV[@]}" "${TASKSET_PRE[@]}" "$BROWSER_BIN" \
    --no-sandbox --disable-gpu --in-process-gpu --enable-low-end-device-mode --disable-dev-shm-usage \
    --renderer-process-limit=1 --disable-extensions --disable-background-networking --disable-sync --disable-default-apps \
    --no-first-run --no-default-browser-check --hide-crash-restore-bubble --noerrdialogs --disable-logging --log-level=3 \
    --disable-crash-reporter --no-crash-upload --disable-breakpad --disable-hang-monitor --disable-gpu-watchdog \
    --disable-client-side-phishing-detection --disable-domain-reliability --no-pings --disable-notifications \
    --block-new-web-contents --deny-permission-prompts --disable-component-update --disable-component-extensions-with-background-pages \
    --disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows \
    --aggressive-cache-discard --disk-cache-size=1048576 --media-cache-size=1048576 --password-store=basic \
    --force-color-profile=srgb --hide-scrollbars --disable-smooth-scrolling --autoplay-policy=no-user-gesture-required \
    --kiosk --window-size="${STREAM_WIDTH},${STREAM_HEIGHT}" --window-position=0,0 \
    --user-data-dir="$GR/chrome-profile" --js-flags="--max-old-space-size=${MEM} --optimize-for-size" \
    --disable-features=Translate,TranslateUI,MediaRouter,DialMediaRouteProvider,OptimizationHints,InterestFeedContentSuggestions,PrivacySandboxSettings4,AutofillServerCommunication,GlobalMediaControls,HeavyAdPrivacyMitigations,CalculateNativeWinOcclusion,PaintHolding \
    "${CHROME_AUDIO[@]}" --app="http://127.0.0.1:$PORT/?$QUERY" >"$LOG_DIR/chromium_${GROUP}.log" 2>&1 &
  echo $! > "$CHROME_PID"; sleep 3
fi

echo "$SIG" > "$GR/signature"
printf 'GROUP=%s\nLAYOUT=%s\nPROFILE=%s\nWIDTH=%s\nHEIGHT=%s\nDISPLAY=%s\nCITIES=%s\nMASTER=%s\n' "$GROUP" "$LAYOUT" "$PROFILE_REQ" "$STREAM_WIDTH" "$STREAM_HEIGHT" "$DISPLAY_NUM" "${CITIES:-}" "${MASTER:-${GROUP_AUDIO_MASTER:-0}}" > "$GR/ui.env"
echo "[$(date '+%F %T')] UI $GROUP ready: ${STREAM_WIDTH}x${STREAM_HEIGHT} layout=$LAYOUT profile=$PROFILE_REQ display=:$DISPLAY_NUM master=${MASTER:-${GROUP_AUDIO_MASTER:-0}}"
