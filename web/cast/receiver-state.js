(function (root) {
  'use strict';
  function createState() {
    let sessionId = null;
    let sequence = -1;
    let timestampEpochMs = -1;
    let payload = null;
    return {
      apply(message) {
        if (!message || !message.payload) return { accepted: false, reason: 'missing-state' };
        const next = message.payload;
        if (sessionId !== next.sessionId) {
          if (message.type !== 'FULL_STATE') return { accepted: false, reason: 'foreign-session' };
          if (next.timestampEpochMs <= timestampEpochMs) return { accepted: false, reason: 'stale-session' };
          sessionId = next.sessionId;
          sequence = -1;
        } else if (next.timestampEpochMs < timestampEpochMs) {
          return { accepted: false, reason: 'stale-timestamp' };
        }
        if (next.sequence <= sequence) return { accepted: false, reason: 'stale' };
        sequence = next.sequence;
        timestampEpochMs = next.timestampEpochMs;
        if (message.type === 'DISPLAY_SETTINGS') {
          if (!payload) return { accepted: false, reason: 'missing-state' };
          payload = { ...payload, displaySettings: next.settings };
        } else {
          payload = next;
        }
        return { accepted: true, payload };
      },
      reset() { sessionId = null; sequence = -1; timestampEpochMs = -1; payload = null; },
      get payload() { return payload; },
      get sequence() { return sequence; },
    };
  }
  root.QuranCastState = Object.freeze({ createState });
})(typeof globalThis !== 'undefined' ? globalThis : this);
