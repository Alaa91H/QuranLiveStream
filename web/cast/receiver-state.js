(function (root) {
  'use strict';
  function createState() {
    let sessionId = null;
    let sequence = -1;
    let payload = null;
    return {
      apply(message) {
        if (!message || !message.payload) return { accepted: false, reason: 'missing-state' };
        const next = message.payload;
        if (sessionId !== next.sessionId) {
          if (message.type !== 'FULL_STATE') return { accepted: false, reason: 'foreign-session' };
          sessionId = next.sessionId;
          sequence = -1;
        }
        if (next.sequence <= sequence) return { accepted: false, reason: 'stale' };
        sequence = next.sequence;
        payload = next;
        return { accepted: true, payload };
      },
      get payload() { return payload; },
      get sequence() { return sequence; },
    };
  }
  root.QuranCastState = Object.freeze({ createState });
})(typeof globalThis !== 'undefined' ? globalThis : this);
