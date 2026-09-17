// Shared recitation position for multi-canvas broadcasts.
// group0 (master=1) owns audio/timing; every follower mirrors its verse only.
(() => {
  const params = new URLSearchParams(location.search);
  const isQa = params.get('qa') === '1' || params.get('test') === 'longest';
  const isMaster = params.get('master') !== '0'; // normal browser preview stays standalone
  let lastRevision = 0;
  let followerBusy = false;

  async function publishPosition(surah, ayah) {
    if (!Number.isInteger(Number(surah)) || !Number.isInteger(Number(ayah))) return;
    try {
      const r = await fetch(`/api/playback?surah=${Number(surah)}&ayah=${Number(ayah)}`, {
        method: 'POST',
        headers: { 'X-Quran-Master': '1' },
        cache: 'no-store'
      });
      if (r.ok) {
        const p = await r.json();
        lastRevision = Math.max(lastRevision, Number(p.revision || 0));
      }
    } catch {}
  }

  async function followMaster() {
    if (followerBusy) return;
    try {
      const r = await fetch('/api/playback', { cache: 'no-store' });
      if (!r.ok) return;
      const p = await r.json();
      const revision = Number(p.revision || 0);
      const surah = Number(p.surah || 0);
      const ayah = Number(p.ayah || 0);
      if (revision <= 0 || revision === lastRevision || surah < 1 || ayah < 1) return;
      lastRevision = revision;
      if (typeof state !== 'undefined' && state.currentSurah === surah && state.currentAyah === ayah) return;
      followerBusy = true;
      try { await loadQuranVerse(surah, ayah); } finally { followerBusy = false; }
    } catch {}
  }

  document.addEventListener('DOMContentLoaded', () => {
    if (isQa) return;

    if (isMaster) {
      // Publish immediately before the audible track starts, so follower canvases
      // switch their text at the same verse boundary without decoding audio.
      const originalPlayRecitation = playRecitation;
      playRecitation = function synchronizedMasterPlayback(q) {
        publishPosition(Number(q?.surah || 0), Number(q?.ayah || 0));
        return originalPlayRecitation(q);
      };
      // Republish periodically so followers recover after a web-server restart.
      setInterval(() => {
        if (typeof state !== 'undefined') publishPosition(Number(state.currentSurah), Number(state.currentAyah));
      }, 5000);
      return;
    }

    // Followers render only. They must never maintain a second audio clock or
    // advance independently from the master canvas.
    playRecitation = function followerNoAudio() {};
    preloadNextAyah = function followerNoAudioPreload() {};
    scheduleFallbackAdvance = function followerNoFallbackClock() {};
    advanceToNextAyah = function followerNoIndependentAdvance() {};
    setTimeout(followMaster, 200);
    setInterval(followMaster, 750);
  });
})();
