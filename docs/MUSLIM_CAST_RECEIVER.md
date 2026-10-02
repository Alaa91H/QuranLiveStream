# Muslim Google Cast Quran Receiver

This repository hosts the Custom Web Receiver used by Muslim at `/cast/receiver.html`. Muslim remains the playback authority and sends media through the standard Cast media channel. This page only renders Quran metadata and the current ayah; it does not select or advance ayahs.

## Receiver contract

- Namespace: `urn:x-cast:org.muslim.quran`.
- Current payload schema: version `2`.
- State messages include `FULL_STATE`, `AYAH_CHANGED`, `METADATA_CHANGED`, `RECITER_CHANGED`, and `DISPLAY_SETTINGS`.
- State envelopes carry `sessionId`, monotonically increasing `sequence`, and `timestampEpochMs`. The receiver rejects old sequences, old timestamps, and a replacement session whose full state predates the current session.
- The receiver binds custom messages to the first valid sender. It responds to that sender only, ignores other senders until the active sender disconnects, then clears receiver state so the next sender must provide a fresh full state.
- `UI_READY`, `REQUEST_FULL_STATE`, `MEDIA_ERROR`, and `UNSUPPORTED_SCHEMA` are receiver responses. Media controls and audio loading remain on the Cast media protocol.
- `DISPLAY_SETTINGS` accepts a versioned envelope with a `settings` object. Supported flags are `showTranslation`, `showTafsir`, and `showPrayerTimes`.

## Deployment and registration

1. Serve this repository's `web` directory over public HTTPS, preserving the `/cast/` and `/shared/` paths. Configure the Google Cast Console Web Receiver URL as `https://<host>/cast/receiver.html`.
2. Register a Custom Receiver application in the Google Cast Console and configure its real eight-character application ID in the Muslim Android build as `CAST_RECEIVER_APP_ID`. Never commit a fabricated ID.
3. Configure the same HTTPS receiver URL and application ID in the app's deployment configuration. The standard media receiver fallback supports audio only and does not load this Quran UI.
4. Test with a registered Cast device and the Muslim Android sender. Confirm that audio and metadata are sent independently over their respective Cast channels.

## Local quality checks

Run `npm test` from the repository root. This runs repository quality gates and the receiver protocol/state harness, including session ordering, settings, sender binding, disconnect recovery, long ayah rendering, and missing translation/tafsir handling. The harness does not replace testing against Google Cast hardware or the live Cast Application Framework.

## Security and privacy boundary

The receiver consumes Quran metadata and audio URLs selected by Muslim. This web receiver does not ingest local files, run broadcast workers, or upload offline recitations. Only the active Cast sender can update the receiver during its connection. Deploy only over HTTPS, and use the Android local media bridge for offline files; local Android paths must never be sent as Cast media URLs.
