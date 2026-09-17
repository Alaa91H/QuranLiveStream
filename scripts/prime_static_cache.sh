#!/bin/bash
# ==============================================================================
# Quran Live Stream — Static Asset Primer (first-run data saver)
# Downloads everything STATIC once (fonts, full recitation audio, backgrounds)
# so the 24/7 runtime serves from disk and stops re-spending bandwidth.
# DYNAMIC data is intentionally NOT primed and keeps fetching live:
#   - clock ticks client-side (no network at all)
#   - prayer times are date-keyed (auto-refresh daily)
#   - weather refreshes on its 24h TTL
# Safe to run any time: per-group marker files skip completed work, downloads
# resume where they stopped, and only one instance runs (flock).
# Knobs (.env): PRIME_STATIC=0 disables all, PRIME_AUDIO=0 skips the big
# recitation download (~3.5GB). --light-only (used by broadcast_ui on the hot
# path) does fonts+backgrounds synchronously and NEVER starts the audio fetch:
# no bulk background work may compete with the live encode.
# ==============================================================================
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASE_DIR"

LIGHT_ONLY=0
[ "${1:-}" = "--light-only" ] && LIGHT_ONLY=1

[ -f .env ] && { set -a; source .env; set +a; }

LOG_DIR="$BASE_DIR/logs"
RUNTIME="$BASE_DIR/runtime"
AUDIO_DIR="$BASE_DIR/web/assets/audio"
mkdir -p "$LOG_DIR" "$RUNTIME" "$AUDIO_DIR"
LOG="$LOG_DIR/prime_static.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PRIME] $*" | tee -a "$LOG"
}

if [ "${PRIME_STATIC:-1}" = "0" ]; then
  log "Disabled via PRIME_STATIC=0, skipping."
  exit 0
fi

exec 9>"$RUNTIME/prime_static.lock"
flock -n 9 || { log "Another primer is running, exiting."; exit 0; }

# --- 1. Fonts (KBs, fast): Amiri + Cairo as local woff2 -----------------------
FONTS_CSS="$BASE_DIR/web/assets/fonts/fonts.css"
if [ -f "$RUNTIME/prime-fonts.done" ] && [ -f "$FONTS_CSS" ]; then
  log "Fonts: already primed, skipping."
else
  if command -v node >/dev/null 2>&1; then
    log "Fonts: downloading offline woff2 set..."
    if node "$BASE_DIR/scripts/download_fonts.js" >>"$LOG" 2>&1; then
      touch "$RUNTIME/prime-fonts.done"
      log "Fonts: done."
    else
      log "Fonts: FAILED (will retry next start, runtime falls back to CDN)."
    fi
  else
    log "Fonts: node not found, skipping (runtime falls back to CDN)."
  fi
fi

# --- 2. Backgrounds/images (small, fast) --------------------------------------
if [ -f "$RUNTIME/prime-backgrounds.done" ]; then
  log "Backgrounds: already primed, skipping."
else
  log "Backgrounds: ensuring local set..."
  if "$BASE_DIR/scripts/download_backgrounds.sh" >>"$LOG" 2>&1; then
    touch "$RUNTIME/prime-backgrounds.done"
    log "Backgrounds: done."
  else
    log "Backgrounds: FAILED (will retry next start)."
  fi
fi

# --- 3. Full recitation audio (GBs, slow): resume-safe, niced -----------------
# NEVER on the streaming hot path (--light-only): bulk fetch belongs to
# `control.sh prepare` / first_boot. Here it additionally refuses to run while
# an encoder is active, so it can never drain a live broadcast.
if [ "$LIGHT_ONLY" = "1" ]; then
  log "Audio: skipped (light-only mode)."
elif [ "${PRIME_AUDIO:-1}" = "0" ]; then
  log "Audio: disabled via PRIME_AUDIO=0, skipping."
elif [ -f "$RUNTIME/prime-audio.done" ]; then
  log "Audio: already primed, skipping."
else
  COUNT=$(find "$AUDIO_DIR" -maxdepth 1 -name '*.mp3' -size +1000c 2>/dev/null | wc -l | tr -d ' ')
  case "$COUNT" in ''|*[!0-9]*) COUNT=0;; esac
  if [ "$COUNT" -ge 6236 ]; then
    touch "$RUNTIME/prime-audio.done"
    log "Audio: full set already on disk ($COUNT files)."
  elif pgrep -f "ffmpeg.*(x11grab|current\.mp4)" >/dev/null 2>&1; then
    log "Audio: encoder active, refusing bulk download during stream ($COUNT/6236). Run control.sh prepare while stopped."
  else
    # Never trade a bandwidth optimization for a full filesystem. Estimate the
    # remaining corpus from the documented ~3.5GB set and keep a safety reserve.
    FREE_MB="$(df -Pm "$AUDIO_DIR" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
    USED_MB="$(du -sm "$AUDIO_DIR" 2>/dev/null | awk '{print $1}' || echo 0)"
    case "$FREE_MB" in ''|*[!0-9]*) FREE_MB=0;; esac
    case "$USED_MB" in ''|*[!0-9]*) USED_MB=0;; esac
    EST_TOTAL_MB="${AUDIO_PRIME_EST_MB:-3800}"; RESERVE_MB="${AUDIO_PRIME_RESERVE_MB:-768}"
    case "$EST_TOTAL_MB" in ''|*[!0-9]*) EST_TOTAL_MB=3800;; esac
    case "$RESERVE_MB" in ''|*[!0-9]*) RESERVE_MB=768;; esac
    REMAIN_MB=$((EST_TOTAL_MB-USED_MB)); [ "$REMAIN_MB" -lt 0 ] && REMAIN_MB=0
    NEED_MB=$((REMAIN_MB+RESERVE_MB))
    if [ "$FREE_MB" -lt "$NEED_MB" ]; then
      log "Audio: bulk prime skipped; ${FREE_MB}MB free but ~${NEED_MB}MB is needed (remaining estimate + reserve). Runtime will keep using local hits/CDN fallback."
    elif command -v flock >/dev/null 2>&1 && ! flock -n "$RUNTIME/audio-download.lock" -c true 2>/dev/null; then
      log "Audio: downloader already active; refusing duplicate bulk job."
    else
      log "Audio: priming full recitation in background ($COUNT/6236, free=${FREE_MB}MB, reserve=${RESERVE_MB}MB)..."
      nice -n 10 nohup "$BASE_DIR/scripts/download_all_recitations.sh" >>"$LOG" 2>&1 &
      echo $! >"$RUNTIME/prime-audio.pid"
      log "Audio: downloader pid $(cat "$RUNTIME/prime-audio.pid"), progress in $LOG."
    fi
  fi
fi

# --- 4. Verse JSONs are NOT bulk-primed ---------------------------------------
# 6236 ayahs x 4 APIs would hammer third-party rate limits; on-demand fetch +
# 30-day server cache (see server.js) already makes each verse cost ~zero
# after its first display. Nothing to do here by design.
log "Static prime pass finished (audio may still be downloading in background)."
