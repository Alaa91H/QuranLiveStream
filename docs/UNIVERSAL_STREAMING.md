# Universal Native Streaming Engine

QuranLiveStream publishes only the destinations selected in `STREAM_TARGETS` and builds a native render/encode plan for those targets.

## Native-frame invariant

For every output group:

```text
Browser viewport == Xvfb screen == FFmpeg x11grab frame == encoded frame
```

The universal worker does not use `scale`, `crop` or `pad` to convert one platform aspect ratio into another. Landscape, portrait and square destinations receive independent responsive canvases when necessary.

Default aspect families:

- landscape `16:9`: YouTube, Facebook, Twitch, Kick and generic/custom RTMP;
- portrait `9:16`: TikTok, Instagram/Reels, Shorts/vertical aliases;
- square `1:1`: available to any custom destination via `NAME_LAYOUT=square`.

Per-target overrides use the upper-cased target prefix:

```env
CUSTOM1_LAYOUT=square
CUSTOM1_MAX_PROFILE=balanced
CUSTOM1_MAX_FPS=30
CUSTOM1_MAX_VIDEO_BITRATE=6000k
CUSTOM1_VIDEO_CODEC=h264
```

## Planning policy

`QUALITY_POLICY=auto` chooses between:

- `efficient`: compatible destinations share an encoder;
- `maximize`: capable hardware may split compatible destinations into different quality groups so a high-cap platform is not forced down to another platform's lower maximum.

The planner never raises quality above the measured host ceiling. A user-provided `STREAM_PROFILE` can lower the ceiling but cannot force a weak host upward.

## Resource control

Three layers protect the host:

1. progressive benchmark determines the maximum candidate tier;
2. live governor watches total CPU, RAM and the slowest active FFmpeg worker and downshifts under pressure;
3. systemd CPU/memory accounting provides a final cgroup safety envelope.

Default live thresholds:

```env
RESOURCE_CPU_SOFT=78
RESOURCE_CPU_HARD=88
RESOURCE_RAM_SOFT=82
RESOURCE_RAM_HARD=89
SYSTEMD_CPU_HARD_PCT=90
RESOURCE_SPEED_SOFT=0.97
```

If pressure continues at `nano`, the governor reduces FPS and visible city count. At the absolute minimum floor it holds the stream under the cgroup quota instead of repeatedly restarting it.

## Platform selection

```bash
./scripts/control.sh start youtube
./scripts/control.sh start youtube,tiktok
./scripts/control.sh start youtube,tiktok,facebook,twitch,kick
./scripts/control.sh targets
./scripts/control.sh plan
```

Any RTMP/RTMPS service can be added without a new script:

```env
STREAM_TARGETS=youtube,myservice
MYSERVICE_RTMP_TARGET=rtmps://ingest.example.com/app/private-key
MYSERVICE_LAYOUT=landscape
```

## Fresh-server setup

```bash
cp .env.example .env
chmod 600 .env
nano .env
chmod +x scripts/*.sh
./scripts/first_boot.sh --force
./scripts/setup_cron.sh
./scripts/control.sh preflight
./scripts/control.sh plan
./scripts/control.sh start
```

## Observability

Useful runtime state:

- `runtime/stream_plan.txt` — current native groups;
- `runtime/resources.json` — latest global resource sample;
- `runtime/groups/g*/worker.env` — dimensions/FPS/bitrate/encoder per group;
- `runtime/groups/g*/ffmpeg.progress` — realtime encoder progress;
- `logs/stream.log` — coordinator log;
- `logs/stream_g*.log` — per-group FFmpeg logs;
- `logs/resource_governor.log` — adaptive decisions.

## Validation

```bash
node scripts/qa.js
```

GitHub Actions runs Bash/JavaScript syntax checks and the full QA suite on every push to `main`.
