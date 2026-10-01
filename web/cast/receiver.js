(function () {
  'use strict';
  const protocol = QuranCastProtocol;
  const state = QuranCastState.createState();
  const $ = (id) => document.getElementById(id);
  let senderId;
  const send = (type, extra) => window.cast?.framework?.CastReceiverContext?.getInstance()?.sendCustomMessage(protocol.NAMESPACE, senderId, { type, ...extra });
  function render(p) {
    document.documentElement.lang = p.languageTag || 'ar';
    $('surah').textContent = `${p.surahArabicName} (${p.surahNumber}) · ${p.surahLocalizedName}`;
    $('reference').textContent = `الآية ${p.ayahNumber} من ${p.totalAyahs}`;
    $('ayah').textContent = p.arabicAyah;
    $('translation').textContent = p.translation?.text || '';
    $('translation').lang = p.translation?.languageTag || p.languageTag || 'und';
    $('translation').dir = $('translation').lang.startsWith('ar') ? 'rtl' : 'ltr';
    $('reciter').textContent = `${p.reciterName} · ${p.reciterId}`;
    const tafsir = $('tafsir'); tafsir.replaceChildren();
    for (const item of p.tafsir || []) {
      const article = document.createElement('article');
      const heading = document.createElement('h2'); heading.textContent = item.source || item.languageTag || 'التفسير';
      const paragraph = document.createElement('p'); paragraph.textContent = item.text || ''; paragraph.lang = item.languageTag || 'und'; paragraph.dir = paragraph.lang.startsWith('ar') ? 'rtl' : 'ltr';
      article.append(heading, paragraph); tafsir.append(article);
    }
    if (!p.tafsir?.length) { const article = document.createElement('article'); article.textContent = 'لا يتوفر تفسير لهذه الآية'; tafsir.append(article); }
    const prayers = $('prayers'); prayers.replaceChildren();
    $('location').textContent = p.prayerLocation ? `${p.prayerLocation.city}${p.prayerLocation.countryCode ? ` · ${p.prayerLocation.countryCode}` : ''}` : '';
    for (const time of p.prayerTimes || []) {
      const cell = document.createElement('div'); cell.className = 'prayer';
      const label = document.createElement('span'); label.textContent = time.name;
      const value = document.createElement('strong'); value.textContent = time.localTime;
      cell.append(label, value); prayers.append(cell);
    }
    $('status').textContent = p.playbackState === 'PLAYING' ? 'يُتلى الآن' : 'متوقف مؤقتًا';
    const duration = Number(p.durationMs || 0);
    const position = Number(p.positionMs || 0);
    $('progress').style.width = `${duration > 0 ? Math.min(100, position / duration * 100) : 0}%`;
  }
  const context = cast.framework.CastReceiverContext.getInstance();
  const manager = context.getPlayerManager();
  const stateTypes = new Set(['FULL_STATE','AYAH_CHANGED','METADATA_CHANGED','DISPLAY_SETTINGS','RECITER_CHANGED']);
  context.addCustomMessageListener(protocol.NAMESPACE, (event) => {
    senderId = event.senderId;
    let message;
    try { message = protocol.parse(event.data); }
    catch (error) {
      send(error.message === 'unsupported-schema' ? 'UNSUPPORTED_SCHEMA' : 'MEDIA_ERROR', { supportedVersion: protocol.VERSION });
      return;
    }
    if (stateTypes.has(message.type)) {
      const update = state.apply(message);
      if (update.accepted) render(update.payload);
    }
  });
  manager.setMessageInterceptor(cast.framework.messages.MessageType.LOAD, (request) => {
    if (request.media?.contentId) {
      $('status').textContent = 'يتم تحميل التلاوة';
    }
    return request;
  });
  manager.addEventListener(cast.framework.messages.EventType.ERROR, () => send('MEDIA_ERROR', {}));
  context.start({ receiverDisplayStatus: { statusText: 'القرآن الكريم · تطبيق مسلم' } });
  send('UI_READY', {});
  send('REQUEST_FULL_STATE', {});
})();
