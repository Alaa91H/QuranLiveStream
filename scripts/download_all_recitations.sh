#!/bin/bash
# ==============================================================================
# Quran Live Stream - Autonomous Complete Recitation Downloader (Alafasy 128k)
# Downloads and caches all 6,236 Quran verse audio files to local disk.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AUDIO_DIR="$ROOT_DIR/web/assets/audio"
RUNTIME="$ROOT_DIR/runtime"
mkdir -p "$AUDIO_DIR" "$RUNTIME"

# The static primer launches this script in the background, so its own flock is
# released immediately. Hold a second lock for the downloader lifetime to ensure
# repeated prepare/first-boot runs can never start multi-GB duplicate downloads.
if command -v flock >/dev/null 2>&1; then
  exec 8>"$RUNTIME/audio-download.lock"
  flock -n 8 || { echo "Audio downloader already running; exiting duplicate request."; exit 0; }
fi

echo "=== بدء تحميل التلاوة الصوتية الكاملة بصوت الشيخ مشاري العفاسي (128kbps) ==="
echo "المجلد المستهدف: $AUDIO_DIR"

mark_complete_if_ready() {
  local total
  total="$(find "$AUDIO_DIR" -maxdepth 1 -name '*.mp3' -size +1000c 2>/dev/null | wc -l | tr -d ' ')"
  case "$total" in ''|*[!0-9]*) total=0;; esac
  if [ "$total" -ge 6236 ]; then touch "$RUNTIME/prime-audio.done"; fi
  echo "إجمالي ملفات التلاوة الموجودة على القرص: $total / 6236"
}

# Check if node is available to run high-performance downloader.
if command -v node >/dev/null 2>&1; then
  echo "تشغيل محمل التلاوات الذكي عبر Node.js..."
  set +e
  node "$SCRIPT_DIR/download_all_recitations.js" "$@"
  rc=$?
  set -e
  mark_complete_if_ready
  exit "$rc"
fi

# Fallback shell-only downloader using curl and tar/unzip.
BASE_URL="https://everyayah.com/data/Alafasy_128kbps/zips"
cd "$AUDIO_DIR"

for i in $(seq -w 001 114); do
  echo "⬇ فحص / تنزيل السورة $i ..."
  ZIP_FILE="${i}.zip"
  if curl -s -f -L -o "$ZIP_FILE" "$BASE_URL/$ZIP_FILE" --retry 3 --connect-timeout 10 --max-time 180; then
    if command -v tar >/dev/null 2>&1; then
      tar -xf "$ZIP_FILE" && rm -f "$ZIP_FILE"
    elif command -v unzip >/dev/null 2>&1; then
      unzip -o -q "$ZIP_FILE" && rm -f "$ZIP_FILE"
    fi
    echo "✓ تم استخراج سورة $i"
  else
    rm -f "$ZIP_FILE"
    echo "تنبيه: تعذر تحميل الحزمة لسورة $i، سيتم التحميل التلقائي الفردي عند البث."
  fi
done

echo "=== اكتملت عملية التنزيل ==="
mark_complete_if_ready
