'use strict';
// Loaded with Node --require before server.js. It wraps the existing HTTP server
// and adds a localhost-only, in-memory recitation position bus without another
// process. It also guards opportunistic MP3 caching against filling the disk.
const http = require('http');
const fs = require('fs');
const path = require('path');

const originalCreateServer = http.createServer.bind(http);
const originalWriteFileSync = fs.writeFileSync.bind(fs);
const AUDIO_DIR = path.resolve(__dirname, 'assets', 'audio');
const AUDIO_CACHE_MIN_FREE_MB = Math.min(Math.max(Number(process.env.AUDIO_CACHE_MIN_FREE_MB || 768) || 768, 64), 65536);
const STORAGE_SAMPLE_MS = 30000;
let storageSample = { checkedAt: 0, freeMB: null, writable: false, reason: 'not-sampled' };
let surahs = [];
try { surahs = JSON.parse(fs.readFileSync(path.join(__dirname, 'surahs.json'), 'utf8')); } catch {}
let playback = { surah: 1, ayah: 1, revision: 0, updatedAt: 0 };

function audioStorageState(force = false) {
  const now = Date.now();
  if (!force && now - storageSample.checkedAt < STORAGE_SAMPLE_MS) return storageSample;
  try {
    if (typeof fs.statfsSync !== 'function') throw new Error('statfs unavailable');
    const st = fs.statfsSync(AUDIO_DIR);
    const freeMB = Math.max(0, Math.floor((Number(st.bavail) * Number(st.bsize)) / (1024 * 1024)));
    storageSample = {
      checkedAt: now,
      freeMB,
      writable: freeMB >= AUDIO_CACHE_MIN_FREE_MB,
      reason: freeMB >= AUDIO_CACHE_MIN_FREE_MB ? 'ok' : 'low-disk'
    };
  } catch {
    // Streaming must continue even when free-space telemetry is unavailable.
    // Refuse only optional local caching and let the UI use the CDN fallback.
    storageSample = { checkedAt: now, freeMB: null, writable: false, reason: 'statfs-unavailable' };
  }
  return storageSample;
}

// server.js writes downloaded ayahs to <verse>.mp3.tmp-<pid> before rename.
// Guard only those optional cache writes; never interfere with JSON/log/runtime
// state. Throwing here is caught by the existing background-download promise.
fs.writeFileSync = function guardedWriteFileSync(file, ...args) {
  let resolved = '';
  try { resolved = path.resolve(String(file)); } catch {}
  const isAudioTemp = resolved.startsWith(AUDIO_DIR + path.sep) && /\.mp3\.tmp-[^/\\]+$/.test(resolved);
  if (isAudioTemp) {
    const state = audioStorageState();
    if (!state.writable) {
      const err = new Error(`Audio cache write skipped: ${state.reason}`);
      err.code = 'ENOSPC';
      throw err;
    }
  }
  return originalWriteFileSync(file, ...args);
};

function reply(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff'
  });
  res.end(data);
}

function validPosition(surah, ayah) {
  if (!Number.isInteger(surah) || !Number.isInteger(ayah) || surah < 1 || surah > 114 || ayah < 1) return false;
  const meta = surahs.find(s => Number(s.number) === surah);
  return Boolean(meta && ayah <= Number(meta.ayahs || 0));
}

function wrap(listener) {
  return async function quranPlaybackRouter(req, res) {
    let u;
    try { u = new URL(req.url || '/', 'http://127.0.0.1'); } catch { return listener(req, res); }

    if (u.pathname === '/api/storage') {
      if (req.method !== 'GET') return reply(res, 405, { error: 'method not allowed' });
      const s = audioStorageState();
      return reply(res, 200, {
        audioCache: {
          freeMB: s.freeMB,
          minFreeMB: AUDIO_CACHE_MIN_FREE_MB,
          writable: s.writable,
          reason: s.reason,
          sampledAt: s.checkedAt ? new Date(s.checkedAt).toISOString() : null
        }
      });
    }

    if (u.pathname !== '/api/playback') return listener(req, res);
    if (req.method === 'GET') return reply(res, 200, playback);
    if (req.method !== 'POST') return reply(res, 405, { error: 'method not allowed' });

    // A custom header prevents cross-origin simple requests from mutating the
    // local state without a CORS preflight. The server itself is loopback-only.
    if (req.headers['x-quran-master'] !== '1') return reply(res, 403, { error: 'master required' });
    const surah = Number(u.searchParams.get('surah'));
    const ayah = Number(u.searchParams.get('ayah'));
    if (!validPosition(surah, ayah)) return reply(res, 400, { error: 'invalid Quran position' });

    if (playback.revision === 0 || playback.surah !== surah || playback.ayah !== ayah) {
      playback = { surah, ayah, revision: playback.revision + 1, updatedAt: Date.now() };
    } else {
      playback.updatedAt = Date.now();
    }
    return reply(res, 200, playback);
  };
}

http.createServer = function patchedCreateServer(options, listener) {
  if (typeof options === 'function') return originalCreateServer(wrap(options));
  if (typeof listener === 'function') return originalCreateServer(options, wrap(listener));
  return originalCreateServer(options, listener);
};
