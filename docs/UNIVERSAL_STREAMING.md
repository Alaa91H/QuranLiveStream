# Universal Adaptive Streaming

The project now supports one adaptive broadcast engine for any RTMP/RTMPS platform.

## Select only the platforms you want

In `.env`:

```env
STREAM_TARGETS=youtube,tiktok,facebook
```

Only listed targets are published. Remove a slug and the engine will not connect to that platform.

Common variables:

```env
YOUTUBE_RTMP_URL=rtmps://a.rtmps.youtube.com/live2
YOUTUBE_STREAM_KEY=...

TIKTOK_RTMP_URL=rtmp://rtmp.tiktok.com/live
TIKTOK_STREAM_KEY=...

FACEBOOK_RTMP_URL=rtmps://live-api-s.facebook.com:443/rtmp
FACEBOOK_STREAM_KEY=...
```

Any other platform works with the same convention:

```env
STREAM_TARGETS=youtube,myplatform
MYPLATFORM_RTMP_URL=rtmps://ingest.example.com/live
MYPLATFORM_STREAM_KEY=...
```

For custom services that provide a complete publish URL including the key/path, leave `MYPLATFORM_STREAM_KEY` empty and place the complete URL in `MYPLATFORM_RTMP_URL`.

## Single encode, multiple outputs

All selected destinations receive the same encoded stream through FFmpeg's `tee` muxer. Adding a destination therefore primarily increases outbound bandwidth, not x264 CPU load.

A separate platform-specific canvas (for example a simultaneous 16:9 YouTube scene and a different 9:16 TikTok scene) requires an additional render/encode path. That is intentionally not started automatically on low-spec hosts because it can violate the load budget. On a 1-vCPU host, prefer one shared canvas.

## Adaptive load governor

Defaults:

```env
ADAPTIVE_ENABLE=1
CPU_TARGET=80
CPU_HARD_LIMIT=90
RAM_TARGET=82
RAM_HARD_LIMIT=90
ADAPTIVE_SAMPLE_SEC=5
ADAPTIVE_OVERLOAD_SAMPLES=3
ADAPTIVE_UNDERLOAD_SAMPLES=24
ADAPTIVE_COOLDOWN_SEC=180
FFMPEG_MIN_SPEED=0.97
```

The hardware benchmark selects the maximum safe quality. Runtime adaptation may move downward when CPU/RAM pressure or encoder speed indicates overload, and may cautiously move upward after sustained headroom. It never upshifts beyond the measured hardware ceiling.

When a hard CPU or RAM limit is observed, the engine requests an immediate one-step downshift. Resolution changes restart the coordinated Xvfb + Chromium UI at the new dimensions before FFmpeg resumes.

`CPU_HARD_LIMIT=90` is a runtime control target, not a kernel-level guarantee against millisecond scheduling spikes. The design prevents sustained overload and reacts to sampled hard-limit crossings. For a stricter safety margin, use `CPU_TARGET=75` and `CPU_HARD_LIMIT=85`.

## Network governor

`probe_egress.sh` measures safe upload capacity. With multiple selected outputs, the universal engine divides the safe total egress budget by the number of destinations and clamps per-stream bitrate when necessary.

```env
EGRESS_GUARD=1
```

## Install / migrate

```bash
cp .env.example .env
nano .env
chmod +x scripts/*.sh
./scripts/first_boot.sh --force
./scripts/control.sh preflight
./scripts/control.sh start
```

`install_service.sh` creates a portable user-systemd unit using the repository's actual path and disables the old per-platform YouTube/TikTok services to prevent duplicate encoders.

## Operations

```bash
./scripts/control.sh status
./scripts/control.sh logs
./scripts/control.sh targets
./scripts/control.sh restart
./scripts/control.sh stop
./scripts/control.sh reset-adaptive
```

Live telemetry is written to:

- `runtime/load.status`
- `runtime/status.json`
- `runtime/ffmpeg.progress`
- `runtime/adaptive_rank`
- `logs/stream_universal.log`

## 1 vCPU / 1 GB RAM

The existing hardware profiler normally caps this class of server at `micro` (or lower if the benchmark says so). The universal engine can downshift further to `nano` under sustained pressure. File-based recitation audio, ZRAM/swap, low-effects Chromium mode, and one shared encode are preferred for this host class.
