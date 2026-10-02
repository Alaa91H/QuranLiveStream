const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.join(__dirname, '../../../web/cast');
const nodes = new Map();
const makeNode = () => ({ textContent: '', lang: '', dir: '', className: '', style: {}, children: [], append(...children) { this.children.push(...children); }, replaceChildren(...children) { this.children = children; } });
const document = {
  documentElement: makeNode(),
  getElementById(id) { if (!nodes.has(id)) nodes.set(id, makeNode()); return nodes.get(id); },
  createElement: makeNode,
};
let customListener;
let disconnectListener;
const outbound = [];
let receiverContext;
const castFramework = {
  CastReceiverContext: { getInstance: () => receiverContext },
  messages: { MessageType: { LOAD: 'LOAD' }, EventType: { ERROR: 'ERROR' } },
  system: { EventType: { SENDER_DISCONNECTED: 'SENDER_DISCONNECTED' } },
};
const context = { document, window: { cast: { framework: castFramework } } };
const manager = { setMessageInterceptor() {}, addEventListener() {} };
receiverContext = {
  getPlayerManager: () => manager,
  addCustomMessageListener(_namespace, listener) { customListener = listener; },
  addEventListener(_type, listener) { disconnectListener = listener; },
  start() {},
  sendCustomMessage(_namespace, senderId, data) { outbound.push({ senderId, ...data }); },
};
context.cast = context.window.cast;
context.globalThis = context;
for (const file of ['receiver-protocol.js', 'receiver-state.js']) {
  vm.runInNewContext(fs.readFileSync(path.join(root, file), 'utf8'), context, { filename: file });
}
vm.runInNewContext(fs.readFileSync(path.join(root, 'receiver.js'), 'utf8'), context, { filename: 'receiver.js' });
const protocol = context.globalThis.QuranCastProtocol;
const state = context.globalThis.QuranCastState.createState();
const payload = (sequence, extra = {}) => ({
  schemaVersion: 2, sessionId: 'test-session', sequence, timestampEpochMs: 1_800_000_000_000,
  globalAyahNumber: 1, arabicAyah: 'بِسْمِ اللَّهِ', audioUrl: 'https://example.test/001001.mp3', ...extra,
});
assert.equal(protocol.parse({ type: 'FULL_STATE', payload: payload(3) }).payload.sequence, 3);
assert.equal(state.apply(protocol.parse({ type: 'FULL_STATE', payload: payload(3) })).accepted, true);
assert.equal(state.apply(protocol.parse({ type: 'AYAH_CHANGED', payload: payload(2) })).accepted, false);
assert.equal(state.apply(protocol.parse({ type: 'AYAH_CHANGED', payload: payload(99, { sessionId: 'old-session' }) })).accepted, false);
assert.throws(() => protocol.parse({ type: 'FULL_STATE', payload: payload(4, { schemaVersion: 1 }) }), /unsupported-schema/);
assert.equal(state.apply(protocol.parse({ type: 'FULL_STATE', payload: payload(0, { sessionId: 'new-session', timestampEpochMs: 1_799_999_999_999 }) })).accepted, false);
assert.equal(state.apply(protocol.parse({ type: 'FULL_STATE', payload: payload(0, { sessionId: 'new-session', timestampEpochMs: 1_800_000_000_001 }) })).accepted, true);
assert.equal(protocol.parse({ type: 'DISPLAY_SETTINGS', payload: { schemaVersion: 2, sessionId: 'test-session', sequence: 4, timestampEpochMs: 1_800_000_000_002, settings: { showTafsir: false } } }).type, 'DISPLAY_SETTINGS');
const settingsState = context.globalThis.QuranCastState.createState();
settingsState.apply(protocol.parse({ type: 'FULL_STATE', payload: payload(0) }));
assert.equal(settingsState.apply(protocol.parse({ type: 'DISPLAY_SETTINGS', payload: { schemaVersion: 2, sessionId: 'test-session', sequence: 1, timestampEpochMs: 1_800_000_000_001, settings: { showTafsir: false } } })).accepted, true);
assert.equal(settingsState.payload.displaySettings.showTafsir, false);
assert.equal(settingsState.payload.arabicAyah, 'بِسْمِ اللَّهِ');
settingsState.reset();
assert.equal(settingsState.payload, null);

const renderPayload = payload(4, {
  surahNumber: 2, surahArabicName: 'البقرة', surahLocalizedName: 'Al-Baqarah', totalAyahs: 286,
  ayahNumber: 255, reciterName: 'القارئ', reciterId: 'reciter-1',
  arabicAyah: 'آية طويلة '.repeat(300), translation: null, tafsir: [], durationMs: 100_000, positionMs: 25_000,
  prayerLocation: null, prayerTimes: [], playbackState: 'PLAYING',
});
customListener({ senderId: 'sender-1', data: { type: 'FULL_STATE', payload: renderPayload } });
assert.equal(nodes.get('ayah').textContent, renderPayload.arabicAyah);
assert.equal(nodes.get('translation').textContent, '');
assert.match(nodes.get('tafsir').children[0].textContent, /لا يتوفر تفسير/);
assert.equal(nodes.get('progress').style.width, '25%');
assert.equal(nodes.get('surah').textContent, 'البقرة (2) · Al-Baqarah');
assert.equal(outbound.some((message) => message.type === 'UI_READY'), true);
assert.equal(outbound.every((message) => message.senderId === 'sender-1'), true);
const ayahBeforeIntruder = nodes.get('ayah').textContent;
customListener({ senderId: 'sender-2', data: { type: 'FULL_STATE', payload: { ...renderPayload, sessionId: 'attacker', sequence: 1, timestampEpochMs: 1_800_000_000_010, arabicAyah: 'رسالة من مرسل آخر' } } });
assert.equal(nodes.get('ayah').textContent, ayahBeforeIntruder);
disconnectListener({ senderId: 'sender-1' });
customListener({ senderId: 'sender-2', data: { type: 'FULL_STATE', payload: { ...renderPayload, sessionId: 'new-sender', sequence: 0, timestampEpochMs: 1_800_000_000_020, arabicAyah: 'المرسل الجديد' } } });
assert.equal(nodes.get('ayah').textContent, 'المرسل الجديد');
console.log('Cast receiver protocol/state checks passed');
