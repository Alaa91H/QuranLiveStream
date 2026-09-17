#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/quran-live.service"
mkdir -p "$UNIT_DIR" "$BASE_DIR/logs" "$BASE_DIR/runtime"

cat > "$UNIT" <<EOF
[Unit]
Description=Quran Live Universal Adaptive Multi-Platform Stream
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BASE_DIR
EnvironmentFile=-$BASE_DIR/.env
ExecStart=$BASE_DIR/scripts/stream_universal.sh
Restart=always
RestartSec=5
TimeoutStopSec=30
KillMode=control-group
Nice=-5
OOMScoreAdjust=-250
MemoryHigh=85%
MemoryMax=95%
StandardOutput=append:$BASE_DIR/logs/systemd_universal.log
StandardError=append:$BASE_DIR/logs/systemd_universal.log

[Install]
WantedBy=default.target
EOF

chmod +x "$BASE_DIR"/scripts/*.sh 2>/dev/null || true
systemctl --user daemon-reload
# Prevent legacy per-platform services from running extra encoders in parallel.
for old in quran-live-youtube.service quran-live-tiktok.service; do
  systemctl --user stop "$old" >/dev/null 2>&1 || true
  systemctl --user disable "$old" >/dev/null 2>&1 || true
done
systemctl --user enable quran-live.service >/dev/null
if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger "$USER" >/dev/null 2>&1 || true
fi
echo "Installed: $UNIT"
echo "Legacy per-platform services disabled to avoid duplicate encoding."
echo "Start with: $BASE_DIR/scripts/control.sh start"
