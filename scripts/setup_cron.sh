#!/usr/bin/env bash
# Install low-frequency recovery/maintenance jobs. The fast 15s resource loop is
# a systemd user service, not cron, so CPU/RAM protection reacts promptly.
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
chmod +x "$BASE_DIR"/scripts/*.sh 2>/dev/null || true
"$BASE_DIR/scripts/control.sh" install-units >/dev/null 2>&1 || true
if command -v systemctl >/dev/null 2>&1; then systemctl --user enable --now quran-live-governor.service >/dev/null 2>&1 || true; fi
CURRENT="$(crontab -l 2>/dev/null || true)"
CLEAN="$(printf '%s\n' "$CURRENT" | grep -v "$BASE_DIR/scripts" || true)"
{
  printf '%s\n' "$CLEAN"
  echo '# QuranLiveStream autonomous jobs'
  echo "*/2 * * * * $BASE_DIR/scripts/watchdog.sh >/dev/null 2>&1"
  echo "30 3 * * * $BASE_DIR/scripts/maintenance.sh >/dev/null 2>&1"
} | crontab -
echo "✓ watchdog every 2 min; maintenance daily 03:30; resource governor every ${RESOURCE_INTERVAL_SEC:-15}s via systemd"
if [ "${FIRST_BOOT:-1}" = "1" ]; then "$BASE_DIR/scripts/first_boot.sh" || true; fi
