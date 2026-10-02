(function (root) {
  'use strict';
  const VERSION = 2;
  const NAMESPACE = 'urn:x-cast:org.muslim.quran';
  function parse(raw) {
    const message = typeof raw === 'string' ? JSON.parse(raw) : raw;
    if (!message || typeof message !== 'object') throw new Error('invalid-message');
    if (['FULL_STATE', 'AYAH_CHANGED', 'METADATA_CHANGED', 'RECITER_CHANGED', 'DISPLAY_SETTINGS'].includes(message.type)) {
      const payload = message.payload;
      if (!payload || payload.schemaVersion !== VERSION) throw new Error('unsupported-schema');
      if (!payload.sessionId || !Number.isSafeInteger(payload.sequence) || payload.sequence < 0 || !Number.isFinite(payload.timestampEpochMs)) throw new Error('invalid-envelope');
      if (message.type === 'DISPLAY_SETTINGS') {
        if (!payload.settings || typeof payload.settings !== 'object' || Array.isArray(payload.settings)) throw new Error('invalid-payload');
      } else if (!Number.isInteger(payload.globalAyahNumber) || !payload.arabicAyah || !payload.audioUrl) {
        throw new Error('invalid-payload');
      }
    }
    return message;
  }
  function envelope(type, payload) { return { type, payload }; }
  root.QuranCastProtocol = Object.freeze({ VERSION, NAMESPACE, parse, envelope });
})(typeof globalThis !== 'undefined' ? globalThis : this);
