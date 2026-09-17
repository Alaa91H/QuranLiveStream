'use strict';
// Loaded with Node --require before server.js. It wraps the existing HTTP server
// and adds a localhost-only, in-memory recitation position bus without another
// process. The master browser writes; follower canvases only read.
const http = require('http');
const fs = require('fs');
const path = require('path');

const originalCreateServer = http.createServer.bind(http);
let surahs = [];
try { surahs = JSON.parse(fs.readFileSync(path.join(__dirname, 'surahs.json'), 'utf8')); } catch {}
let playback = { surah: 1, ayah: 1, revision: 0, updatedAt: 0 };

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
