#!/bin/bash
# ==============================================================================
# Quran Live Stream — Hardware Profile & Adaptive Streaming Engine
# Automatically detects host CPU, RAM, and GPU to optimize streaming from 720p to 8K.
# Tailored for rock-solid stability on 1 vCPU / 1 GB RAM (e.g. Oracle Cloud Free Tier).
# ==============================================================================

# 1. Detect System Resources
TOTAL_RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || grep MemTotal /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}' || echo 1024)
CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
# Sanitize: empty/non-numeric detection (e.g. missing `free`) must not break
# the integer comparisons below; fall back to conservative 1GB/1CPU.
case "$TOTAL_RAM_MB" in ''|*[!0-9]*) TOTAL_RAM_MB=1024 ;; esac
case "$CPU_CORES" in ''|*[!0-9]*) CPU_CORES=1 ;; esac

# Detect Hardware Acceleration (NVENC, VAAPI, QuickSync)
HAS_NVENC=0
HAS_VAAPI=0
HAS_QSV=0
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -encoders 2>/dev/null | grep -q h264_nvenc && HAS_NVENC=1 || true
  ffmpeg -encoders 2>/dev/null | grep -q h264_vaapi && HAS_VAAPI=1 || true
  ffmpeg -encoders 2>/dev/null | grep -q ' h264_qsv ' && HAS_QSV=1 || true
fi

# 2. Determine Profile (Manual Override via $STREAM_PROFILE or Auto-detection)
# Options: nano (360p last-resort), micro (480p ultra-low), eco (720p),
#          balanced (1080p), high (2K/1440p), ultra (4K), extreme (8K)
# Precedence: explicit STREAM_PROFILE > measured host.env benchmark > auto-detect
HOST_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd || echo .)"
if [ -f "$HOST_ENV_DIR/runtime/host.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$HOST_ENV_DIR/runtime/host.env" 2>/dev/null || true
  set +a
fi
# Normalize: "none" confidential mode displays as nothing
[ "${HOST_CC:-none}" = "none" ] && HOST_CC="" || true
if [ -n "${STREAM_PROFILE:-}" ]; then
  PROFILE="${STREAM_PROFILE,,}"
elif [ -n "${HOST_BENCH_PROFILE:-}" ] && [ "${HOST_AUTO_PROFILE:-1}" = "1" ]; then
  PROFILE="${HOST_BENCH_PROFILE,,}"
elif [ -n "${STREAM_RES:-}" ]; then
  case "${STREAM_RES,,}" in
    360p|ld|nano) PROFILE="nano" ;;
    480p|sd|micro) PROFILE="micro" ;;
    720p|hd) PROFILE="eco" ;;
    1080p|fhd) PROFILE="balanced" ;;
    1440p|2k|qhd) PROFILE="high" ;;
    2160p|4k|uhd) PROFILE="ultra" ;;
    4320p|8k) PROFILE="extreme" ;;
    *) PROFILE="balanced" ;;
  esac
else
  # Auto-select based on hardware
  if [ "$TOTAL_RAM_MB" -le 1000 ] || [ "$CPU_CORES" -le 1 ]; then
    PROFILE="micro" # Ultra-Low Resource Quran Mode (<=1GB RAM or 1 vCPU)
  elif [ "$TOTAL_RAM_MB" -le 1500 ]; then
    PROFILE="eco" # Optimized for Oracle Free Tier (~1GB RAM)
  elif [ "$TOTAL_RAM_MB" -le 4096 ] && [ "$CPU_CORES" -le 3 ]; then
    PROFILE="balanced" # Standard 1080p VPS
  elif [ "$TOTAL_RAM_MB" -ge 16000 ] && [ "$HAS_NVENC" -eq 1 ]; then
    PROFILE="ultra" # 4K with GPU
  elif [ "$TOTAL_RAM_MB" -ge 8192 ] && [ "$CPU_CORES" -ge 6 ]; then
    PROFILE="high" # 2K 1440p
  else
    PROFILE="balanced"
  fi
fi

# Unknown names (typo, stale benchmark file) fall back to balanced, never empty
case "${PROFILE:-}" in
  nano|micro|eco|balanced|high|ultra|extreme) ;;
  *) PROFILE="balanced" ;;
esac

# 3. Configure Resolution, Bitrate, Encoding & Memory Limits
case "$PROFILE" in
  nano)
    # Last-resort fluency (<=700MB RAM or failed benchmark): 360p is coarse
    # for Arabic glyphs, but a fluent 360p beats a stuttering 480p.
    PROFILE_NAME="Nano (360p Last-Resort - tiny RAM/CPU)"
    STREAM_WIDTH=640
    STREAM_HEIGHT=360
    STREAM_FPS="${STREAM_FPS:-10}"
    VIDEO_BITRATE="${VIDEO_BITRATE:-500k}"
    MAX_BITRATE="${MAX_BITRATE:-800k}"
    BUF_SIZE="1200k"
    AUDIO_BITRATE="${AUDIO_BITRATE:-64k}"
    AUDIO_CHANNELS="${AUDIO_CHANNELS:-1}"
    AUDIO_SAMPLERATE=44100
    FFMPEG_PRESET="ultrafast"
    FFMPEG_TUNE="zerolatency"
    FFMPEG_THREADS=1
    # Keep low-cost x264 analysis, but let stream_worker set GOP from the final
    # adaptive FPS so keyframes remain exactly two seconds apart after downshift.
    X264_PARAMS="ref=1:mixed-refs=0:trellis=0:cabac=0:8x8dct=0:weightp=0:me=dia:subme=0:analyse=i4x4:scenecut=0:no-scenecut:no-chroma-me:merange=8:nal-hrd=none:filler=0:force-cfr=1:fast-pskip=1:dct-decimate=1"
    DEFAULT_AUDIO_MODE="file"
    NODE_MEM_MB=96
    CHROME_MEM_MB=128
    VCODEC="libx264"
    ;;

  micro)
    # Ultra-Low Resource Quran Mode (<=1GB RAM or 1 vCPU, e.g. throttled free tier).
    # 854x480 @10fps: mostly-static Quran pages stay readable, CPU ~= 1/3 of eco.
    # File-based audio by default (no PulseAudio in the audio path).
    PROFILE_NAME="Micro (480p Ultra-Low - 1 CPU / <=1GB RAM)"
    STREAM_WIDTH=854
    STREAM_HEIGHT=480
    STREAM_FPS="${STREAM_FPS:-10}"
    VIDEO_BITRATE="${VIDEO_BITRATE:-800k}"
    MAX_BITRATE="${MAX_BITRATE:-1000k}"
    BUF_SIZE="1600k"
    AUDIO_BITRATE="${AUDIO_BITRATE:-64k}"
    AUDIO_CHANNELS="${AUDIO_CHANNELS:-1}"
    AUDIO_SAMPLERATE=44100
    FFMPEG_PRESET="ultrafast"
    FFMPEG_TUNE="zerolatency"
    FFMPEG_THREADS=1
    # Verified extra savings on top of ultrafast+zerolatency (which already set
    # cabac=0 ref=1 bframes=0 deblock=off aq-mode=0 weightp=0 8x8dct=0 me=dia
    # subme=0 trellis=0 mixed-refs=0 mbtree=0 scenecut=0 partitions=none):
    # no chroma-ME, tight dia range, no filler. Adaptive GOP is supplied by
    # stream_worker after platform/governor FPS caps are applied.
    # Deliberately NOT included: no-psy (softens glyph edges for ~0% CPU),
    # profile baseline (worse text compression at same CBR), threads>1.
    X264_PARAMS="ref=1:mixed-refs=0:trellis=0:cabac=0:8x8dct=0:weightp=0:me=dia:subme=0:analyse=i4x4:scenecut=0:no-scenecut:no-chroma-me:merange=8:nal-hrd=none:filler=0:force-cfr=1:fast-pskip=1:dct-decimate=1"
    DEFAULT_AUDIO_MODE="file"
    NODE_MEM_MB=112
    CHROME_MEM_MB=160
    VCODEC="libx264"
    ;;

  eco)
    # Low-spec Cloud (Oracle Cloud Free Tier: 1 CPU, 1GB RAM)
    PROFILE_NAME="Eco (720p HD - 1 CPU / 1GB RAM optimized)"
    STREAM_WIDTH=1280
    STREAM_HEIGHT=720
    STREAM_FPS="${STREAM_FPS:-15}"
    VIDEO_BITRATE="${VIDEO_BITRATE:-1200k}"
    MAX_BITRATE="${MAX_BITRATE:-1500k}"
    BUF_SIZE="2400k"
    AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
    AUDIO_SAMPLERATE=44100
    FFMPEG_PRESET="ultrafast"
    FFMPEG_TUNE="zerolatency"
    FFMPEG_THREADS=1
    NODE_MEM_MB=140
    CHROME_MEM_MB=220
    VCODEC="libx264"
    ;;

  balanced)
    # Standard 1080p Broadcast (2-4 Cores, 2GB-4GB RAM)
    PROFILE_NAME="Balanced (1080p Full HD)"
    STREAM_WIDTH=1920
    STREAM_HEIGHT=1080
    STREAM_FPS=30
    VIDEO_BITRATE="${VIDEO_BITRATE:-4200k}"
    MAX_BITRATE="${MAX_BITRATE:-4800k}"
    BUF_SIZE="8400k"
    AUDIO_BITRATE="${AUDIO_BITRATE:-160k}"
    AUDIO_SAMPLERATE=48000
    FFMPEG_PRESET="veryfast"
    FFMPEG_TUNE="zerolatency"
    FFMPEG_THREADS=$((CPU_CORES > 2 ? 3 : CPU_CORES))
    NODE_MEM_MB=256
    CHROME_MEM_MB=384
    VCODEC="libx264"
    ;;

  high)
    # 2K Quad HD (4-8 Cores, 8GB+ RAM)
    PROFILE_NAME="High (1440p 2K QHD 60fps)"
    STREAM_WIDTH=2560
    STREAM_HEIGHT=1440
    STREAM_FPS=60
    VIDEO_BITRATE="${VIDEO_BITRATE:-8500k}"
    MAX_BITRATE="${MAX_BITRATE:-9500k}"
    BUF_SIZE="16000k"
    AUDIO_BITRATE="${AUDIO_BITRATE:-192k}"
    AUDIO_SAMPLERATE=48000
    FFMPEG_PRESET="faster"
    FFMPEG_TUNE="film"
    FFMPEG_THREADS=$((CPU_CORES > 4 ? 6 : CPU_CORES))
    NODE_MEM_MB=384
    CHROME_MEM_MB=512
    if [ "$HAS_NVENC" -eq 1 ]; then
      VCODEC="h264_nvenc"
      FFMPEG_PRESET="p4"
    else
      VCODEC="libx264"
    fi
    ;;

  ultra)
    # 4K Ultra HD (Dedicated Server / GPU, 16GB+ RAM)
    PROFILE_NAME="Ultra (2160p 4K UHD 60fps)"
    STREAM_WIDTH=3840
    STREAM_HEIGHT=2160
    STREAM_FPS=60
    VIDEO_BITRATE="${VIDEO_BITRATE:-16000k}"
    MAX_BITRATE="${MAX_BITRATE:-18000k}"
    BUF_SIZE="32000k"
    AUDIO_BITRATE="${AUDIO_BITRATE:-256k}"
    AUDIO_SAMPLERATE=48000
    FFMPEG_THREADS=$((CPU_CORES > 8 ? 8 : CPU_CORES))
    NODE_MEM_MB=512
    CHROME_MEM_MB=768
    if [ "$HAS_NVENC" -eq 1 ]; then
      VCODEC="h264_nvenc"
      FFMPEG_PRESET="p5"
    else
      VCODEC="libx264"
      FFMPEG_PRESET="fast"
    fi
    ;;

  extreme)
    # 8K Extreme Broadcast (Workstation / Data Center GPU)
    PROFILE_NAME="Extreme (4320p 8K Broadcast)"
    STREAM_WIDTH=7680
    STREAM_HEIGHT=4320
    STREAM_FPS=60
    VIDEO_BITRATE="${VIDEO_BITRATE:-36000k}"
    MAX_BITRATE="${MAX_BITRATE:-42000k}"
    BUF_SIZE="70000k"
    AUDIO_BITRATE="${AUDIO_BITRATE:-320k}"
    AUDIO_SAMPLERATE=48000
    FFMPEG_THREADS=$CPU_CORES
    NODE_MEM_MB=768
    CHROME_MEM_MB=1024
    if [ "$HAS_NVENC" -eq 1 ]; then
      VCODEC="hevc_nvenc"
      FFMPEG_PRESET="p5"
    else
      VCODEC="libx265"
      FFMPEG_PRESET="fast"
    fi
    ;;
esac

export PROFILE
export PROFILE_NAME
export STREAM_WIDTH
export STREAM_HEIGHT
export STREAM_FPS
export VIDEO_BITRATE
export MAX_BITRATE
export BUF_SIZE
export AUDIO_BITRATE
export AUDIO_SAMPLERATE
export FFMPEG_PRESET
export FFMPEG_TUNE
export FFMPEG_THREADS
export NODE_MEM_MB
export CHROME_MEM_MB
export VCODEC

# Extra x264 tuning (micro profile only; empty = preset defaults elsewhere)
X264_PARAMS="${X264_PARAMS:-}"
export X264_PARAMS
