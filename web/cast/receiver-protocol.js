(function (root) {
  'use strict';
  const VERSION = 2;
  const NAMESPACE = 'urn:x-cast:org.muslim.quran';
  function parse(raw) {
    const message = typeof raw === 'string' ? JSON.parse(raw) : raw;
    if (!message || typeof message !== 'object') throw new Error('invalid-message');
    if (message.type === 'FULL_STATE' || message.type === 'AYAH_CHANGED' || message.type === 'METADATA_CHANGED' || message.type === 'RECITER_CHANGED') {
      const payload = message.payload;
      if (!payload || payload.schemaVersion !== VERSION) throw new Error('unsupported-schema');
      if (!payload.sessionId || !Number.isSafeInteger(payload.sequence) || payload.sequence < 0 || !Number.isFinite(payload.timestampEpochMs)) throw new Error('invalid-envelope');
      if (!Number.isInteger(payload.globalAyahNumber) || !payload.arabicAyah || !payload.audioUrl) throw new Error('invalid-payload');
    }
    return message;
  }
  function envelope(type, payload) { return { type, payload }; }
  root.QuranCastProtocol = Object.freeze({ VERSION, NAMESPACE, parse, envelope });
})(typeof globalThis !== 'undefined' ? globalThis : this);
