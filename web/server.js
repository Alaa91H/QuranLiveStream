const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname);
const PORT = Number(process.env.PORT || 4177);
const OFFLINE = process.env.QURAN_OFFLINE === '1';
const CACHE_DEFAULT_MS = 24 * 60 * 60 * 1000;
const CACHE_MAX_ENTRIES = Math.min(Math.max(Number(process.env.CACHE_MAX_ENTRIES || 512) || 512, 64), 4096);
const cache = new Map();
const inflight = new Map();
const CACHE_DIR = path.join(ROOT, '.cache');
try { fs.mkdirSync(CACHE_DIR, { recursive: true }); } catch {}

function json(res, data, status = 200, cacheControl = 'no-store') {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': cacheControl,
    'X-Content-Type-Options': 'nosniff'
  });
  res.end(body);
}

function cleanHtml(s = '') {
  return String(s).replace(/<[^>]*>/g, ' ').replace(/\[\d+\]/g, '').replace(/\s+/g, ' ').trim();
}

function keyFor(prefix, value) {
  return `${prefix}:${value}`;
}

function diskPath(key) {
  const safe = Buffer.from(key).toString('base64url').slice(0, 180);
  return path.join(CACHE_DIR, safe + '.json');
}
function readDisk(key) {
  try { return JSON.parse(fs.readFileSync(diskPath(key), 'utf8')); } catch { return null; }
}
function writeDisk(key, entry) {
  try { fs.writeFileSync(diskPath(key), JSON.stringify(entry)); } catch {}
}
function rememberCache(key, entry) {
  // Map insertion order gives a tiny dependency-free LRU. Disk remains the
  // durable long-lived cache, while RAM stays bounded on 1GB/low-heap hosts.
  cache.delete(key);
  cache.set(key, entry);
  while (cache.size > CACHE_MAX_ENTRIES) {
    const oldest = cache.keys().next().value;
    if (oldest === undefined) break;
    cache.delete(oldest);
  }
}
async function cached(key, loader, ttl = CACHE_DEFAULT_MS) {
  const now = Date.now();
  const mem = cache.get(key);
  const hit = mem || readDisk(key);
  if (hit && now - hit.time < ttl) {
    rememberCache(key, hit);
    return hit.value;
  }
  if (mem) cache.delete(key);
  if (inflight.has(key)) return inflight.get(key);
  const task = loader().then(value => {
    const entry = { time: Date.now(), value };
    rememberCache(key, entry);
    writeDisk(key, entry);
    return value;
  }).catch(err => {
    if (hit) return hit.value;
    throw err;
  }).finally(() => inflight.delete(key));
  inflight.set(key, task);
  return task;
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: {
      'User-Agent': 'Quran24-7/3.0',
      'Accept': 'application/json',
      ...(options.headers || {})
    },
    signal: AbortSignal.timeout(options.timeout || 4500)
  });
  if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
  return response.json();
}

function localDate(timeZone) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric', month: '2-digit', day: '2-digit'
  }).formatToParts(new Date());
  const out = Object.fromEntries(parts.filter(x => x.type !== 'literal').map(x => [x.type, x.value]));
  return `${out.year}-${out.month}-${out.day}`;
}

function format24(time) {
  const m = String(time || '').match(/(\d{1,2}):(\d{2})/);
  return m ? `${String(Number(m[1])).padStart(2, '0')}:${m[2]}` : '--:--';
}

// AlAdhan method IDs that are stable and intentionally chosen for major local conventions.
// Other countries use eSalah's country-default method as the primary value.
const ALADHAN_METHOD = {
  AF: 1, PK: 1, IN: 1, SA: 4, EG: 5, IR: 7, BH: 8, KW: 9, QA: 10,
  SG: 11, FR: 12, TR: 13, RU: 14, AE: 16
};

const METHOD_LABELS = {
  1: 'جامعة العلوم الإسلامية بكراتشي',
  2: 'الجمعية الإسلامية لأمريكا الشمالية',
  3: 'رابطة العالم الإسلامي',
  4: 'جامعة أم القرى بمكة',
  5: 'هيئة المساحة المصرية',
  7: 'جامعة طهران',
  8: 'منطقة الخليج',
  9: 'دولة الكويت',
  10: 'دولة قطر',
  11: 'سنغافورة',
  12: 'فرنسا',
  13: 'رئاسة الشؤون الدينية التركية',
  14: 'روسيا',
  16: 'دبي'
};

async function prayerAlAdhan(c) {
  const method = ALADHAN_METHOD[c.code] || Number(process.env.PRAYER_METHOD || 3);
  const date = localDate(c.timezone);
  const key = keyFor('prayer-aladhan', `${c.code}:${c.lat.toFixed(4)}:${c.lon.toFixed(4)}:${date}:${method}`);
  return cached(key, async () => {
    const d = date.split('-').reverse().join('-');
    const url = `https://api.aladhan.com/v1/timings/${d}?latitude=${encodeURIComponent(c.lat)}&longitude=${encodeURIComponent(c.lon)}&method=${method}&school=${c.prayerMadhab === 'hanafi' ? 1 : 0}`;
    const payload = await fetchJson(url, { timeout: 4200 });
    const timings = payload?.data?.timings || {};
    return {
      source: 'AlAdhan',
      method,
      methodName: METHOD_LABELS[method] || 'رابطة العالم الإسلامي',
      date,
      timings: Object.fromEntries(['Fajr','Sunrise','Dhuhr','Asr','Maghrib','Isha'].map(k => [k, format24(timings[k])]))
    };
  });
}

async function prayerESalah(c) {
  const date = localDate(c.timezone);
  const key = keyFor('prayer-esalah', `${c.code}:${c.lat.toFixed(4)}:${c.lon.toFixed(4)}:${date}`);
  return cached(key, async () => {
    const params = new URLSearchParams({ lat: c.lat, lng: c.lon, date, timezone: c.timezone, madhab: c.prayerMadhab || 'standard' });
    const payload = await fetchJson(`https://esalah.com/api/v1/times?${params.toString()}`, { timeout: 4200 });
    const t = payload?.times || {};
    return {
      source: 'eSalah',
      method: payload?.method?.slug || 'country-default',
      methodName: payload?.method?.name || 'الافتراضي بحسب الدولة',
      date,
      timings: Object.fromEntries(['Fajr','Sunrise','Dhuhr','Asr','Maghrib','Isha'].map(k => [k, format24(t[k])]))
    };
  });
}

function parseMinutes(t) {
  const m = String(t || '').match(/^(\d{2}):(\d{2})$/);
  return m ? Number(m[1]) * 60 + Number(m[2]) : null;
}

function comparePrayerTimes(a, b) {
  const fields = ['Fajr', 'Sunrise', 'Dhuhr', 'Asr', 'Maghrib', 'Isha'];
  const deltas = fields.map(k => {
    const am = parseMinutes(a?.[k]);
    const bm = parseMinutes(b?.[k]);
    return am == null || bm == null ? null : Math.abs(am - bm);
  }).filter(v => v != null);
  return {
    maxMinutes: deltas.length ? Math.max(...deltas) : null,
    meanMinutes: deltas.length ? Math.round(deltas.reduce((x, y) => x + y, 0) / deltas.length * 10) / 10 : null,
    samples: deltas.length
  };
}

async function verifiedPrayer(c) {
  if (OFFLINE) {
    const date = localDate(c.timezone);
    const timings = { Fajr:'05:00', Sunrise:'06:20', Dhuhr:'12:00', Asr:'15:30', Maghrib:'18:10', Isha:'19:30' };
    return { timings, primary:{source:'QA Fixture',method:'qa',methodName:'QA'}, secondary:{source:'QA Fixture',method:'qa',methodName:'QA'}, verification:{status:'verified',maxMinutes:0,meanMinutes:0,samples:6}, date };
  }
  const [primary, secondary] = await Promise.allSettled([prayerESalah(c), prayerAlAdhan(c)]);
  const p = primary.status === 'fulfilled' ? primary.value : null;
  const s = secondary.status === 'fulfilled' ? secondary.value : null;
  const chosen = p || s;
  if (!chosen) return { timings: null, sources: [], verification: { status: 'unavailable' } };
  const verification = p && s ? comparePrayerTimes(p.timings, s.timings) : { status: 'single-source' };
  if (verification.maxMinutes != null) verification.status = verification.maxMinutes <= 5 ? 'verified' : verification.maxMinutes <= 12 ? 'review' : 'divergent';
  return {
    timings: chosen.timings,
    primary: { source: chosen.source, method: chosen.method, methodName: chosen.methodName },
    secondary: s && p ? { source: s.source, method: s.method, methodName: s.methodName } : null,
    verification,
    date: chosen.date
  };
}

async function weather(c) {
  if (OFFLINE) {
    return { temperature_2m: 22 + (c.code.charCodeAt(0) % 8), temperature_2m_max: 27 + (c.code.charCodeAt(0) % 5), temperature_2m_min: 18 + (c.code.charCodeAt(1) % 5), relative_humidity_2m: 45, wind_speed_10m: 8, weather_code: 1, is_day: 1, time: new Date().toISOString(), timezone: c.timezone };
  }
  const key = keyFor('weather', `${c.code}:${c.lat.toFixed(4)}:${c.lon.toFixed(4)}`);
  return cached(key, async () => {
    const url = `https://api.open-meteo.com/v1/forecast?latitude=${encodeURIComponent(c.lat)}&longitude=${encodeURIComponent(c.lon)}&current=temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&timezone=auto`;
    const d = await fetchJson(url, { timeout: 4200 });
    return {
      temperature_2m: d?.current?.temperature_2m,
      temperature_2m_max: d?.daily?.temperature_2m_max?.[0],
      temperature_2m_min: d?.daily?.temperature_2m_min?.[0],
      relative_humidity_2m: d?.current?.relative_humidity_2m,
      wind_speed_10m: d?.current?.wind_speed_10m,
      weather_code: d?.current?.weather_code,
      is_day: d?.current?.is_day,
      time: d?.current?.time || null,
      timezone: d?.timezone || c.timezone
    };
  });
}

let qfToken = null;
let qfTokenExp = 0;
async function getQfToken() {
  const id = process.env.QF_CLIENT_ID;
  const secret = process.env.QF_CLIENT_SECRET;
  if (!id || !secret) return null;
  if (qfToken && Date.now() < qfTokenExp - 60000) return qfToken;
  const response = await fetch('https://oauth2.quran.foundation/oauth2/token', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Authorization': 'Basic ' + Buffer.from(id + ':' + secret).toString('base64')
    },
    body: new URLSearchParams({ grant_type: 'client_credentials', scope: 'content' }),
    signal: AbortSignal.timeout(5000)
  });
  if (!response.ok) throw new Error(`Quran Foundation token ${response.status}`);
  const data = await response.json();
  qfToken = data.access_token;
  qfTokenExp = Date.now() + Number(data.expires_in || 3600) * 1000;
  return qfToken;
}

async function qfJson(url) {
  const token = await getQfToken();
  if (!token) return null;
  const response = await fetch(url, {
    headers: { 'x-auth-token': token, 'x-client-id': process.env.QF_CLIENT_ID },
    signal: AbortSignal.timeout(5000)
  });
  if (!response.ok) throw new Error(`Quran Foundation ${response.status}`);
  return response.json();
}

async function getTafsir(verseKey) {
  const token = await getQfToken();
  if (!token) return { ar: null, en: null };
  let arId = Number(process.env.QF_AR_TAFSIR_ID || 0);
  const enId = Number(process.env.QF_EN_TAFSIR_ID || 169);
  if (!arId) {
    try {
      const r = await qfJson('https://apis.quran.foundation/content/api/v4/resources/tafsirs?language=ar');
      const arr = r?.tafsirs || [];
      const m = arr.find(x => /مُيَسَّر|الميسر|muyassar/i.test((x.name || '') + ' ' + (x.slug || '')));
      arId = m?.id || 0;
    } catch {}
  }
  const [ar, en] = await Promise.allSettled([
    arId ? qfJson(`https://apis.quran.foundation/content/api/v4/tafsirs/${arId}?verse_key=${verseKey}&per_page=1`) : Promise.resolve(null),
    qfJson(`https://apis.quran.foundation/content/api/v4/tafsirs/${enId}?verse_key=${verseKey}&per_page=1`)
  ]);
  const pick = v => cleanHtml(v?.tafsirs?.[0]?.text || v?.tafsir?.text || '');
  return { ar: ar.status === 'fulfilled' ? pick(ar.value) : null, en: en.status === 'fulfilled' ? pick(en.value) : null };
}

const surahsFile = path.join(ROOT, 'surahs.json');
const surahsData = fs.existsSync(surahsFile) ? JSON.parse(fs.readFileSync(surahsFile, 'utf8')) : [];

const AUDIO_DIR = path.join(ROOT, 'assets', 'audio');
const audioInflight = new Set();
try { fs.mkdirSync(AUDIO_DIR, { recursive: true }); } catch {}

function localAudioReady(localPath) {
  try { return fs.existsSync(localPath) && fs.statSync(localPath).size > 1000; } catch { return false; }
}

function getAyahAudioUrl(surah, ayah) {
  const s = String(surah).padStart(3, '0');
  const a = String(ayah).padStart(3, '0');
  const fileName = `${s}${a}.mp3`;
  const localPath = path.join(AUDIO_DIR, fileName);
  if (localAudioReady(localPath)) return `/assets/audio/${fileName}`;
  // Schedule a deduplicated background download if not yet cached on disk.
  cacheAudioInBackground(fileName, localPath);
  return `https://everyayah.com/data/Alafasy_128kbps/${fileName}`;
}

function cacheAudioInBackground(fileName, localPath) {
  if (OFFLINE || audioInflight.has(fileName) || localAudioReady(localPath)) return;
  audioInflight.add(fileName);
  const url = `https://everyayah.com/data/Alafasy_128kbps/${fileName}`;
  fetch(url, {
    headers: { 'User-Agent': 'QuranLiveStream/3.0' },
    signal: AbortSignal.timeout(15000)
  })
    .then(async r => {
      if (!r.ok) return;
      const buf = Buffer.from(await r.arrayBuffer());
      if (buf.length <= 1000) return;
      const tmp = `${localPath}.tmp-${process.pid}`;
      fs.writeFileSync(tmp, buf);
      fs.renameSync(tmp, localPath);
    })
    .catch(() => {})
    .finally(() => audioInflight.delete(fileName));
}

async function quranVerse(surah = 1, ayah = 1) {
  const surahMeta = surahsData.find(s => s.number === surah) || {
    number: surah,
    nameAr: 'سُورَةُ البَقَرَةِ',
    nameEn: 'Al-Baqarah',
    ayahs: 286,
    type: 'مَدَنِيَّة'
  };

  const isLongest = surah === 2 && ayah === 282;

  if (OFFLINE) {
    return {
      surah,
      ayah,
      globalNumber: isLongest ? 289 : 262,
      arabic: isLongest
        ? 'يَا أَيُّهَا الَّذِينَ آمَنُوا إِذَا تَدَايَنتُم بِدَيْنٍ إِلَىٰ أَجَلٍ مُّسَمًّى فَاكْتُبُوهُ وَلْيَكْتُب بَّيْنَكُمْ كَاتِبٌ بِالْعَدْلِ وَلَا يَأْبَ كَاتِبٌ أَن يَكْتُبَ كَمَا عَلَّمَهُ اللَّهُ فَلْيَكْتُبْ وَلْيُمْلِلِ الَّذِي عَلَيْهِ الْحَقُّ وَلْيَتَّقِ اللَّهَ رَبَّهُ وَلَا يَبْخَسْ مِنْهُ شَيْئًا فَإِن كَانَ الَّذِي عَلَيْهِ الْحَقُّ سَفِيهًا أَوْ ضَعِيفًا أَوْ لَا يَسْتَطِيعُ أَن يُمِلَّ هُوَ فَلْيُمْلِلْ وَلِيُّهُ بِالْعَدْلِ وَاسْتَشْهِدُوا شَهِيدَيْنِ مِن رِّجَالِكُمْ فَإِن لَّمْ يَكُونَا رَجُلَيْنِ فَرَجُلٌ وَامْرَأَتَانِ مِمَّن تَرْضَوْنَ مِنَ الشُّهَدَاءِ أَن تَضِلَّ إِحْدَاهُمَا فَتُذَكِّرَ إِحْدَاهُمَا الْأُخْرَىٰ …'
        : 'اللَّهُ لَا إِلَٰهَ إِلَّا هُوَ الْحَيُّ الْقَيُّومُ',
      surahArabic: surahMeta.nameAr,
      surahEnglish: surahMeta.nameEn,
      revelationType: surahMeta.type === 'مَدَنِيَّة' ? 'Medinan' : 'Meccan',
      revelationTypeAr: surahMeta.type,
      totalAyahs: surahMeta.ayahs,
      translation: isLongest
        ? 'O you who have believed, when you contract a debt for a specified term, write it down. And let a scribe write between you in justice. Let not a scribe refuse to write as Allah has taught him. So let him write and let the one who has the obligation dictate. And let him fear Allah, his Lord, and not leave anything out of it. But if the one who has the obligation is of limited understanding or weak or unable to dictate himself, then let his guardian dictate in justice …'
        : 'Allah! There is no deity except Him, the Ever-Living, the Sustainer of [all] existence.',
      tafsirAr: isLongest
        ? 'يا أيها الذين آمنوا بالله ورسوله، إذا تعاملتم بدَيْن مؤجل إلى أجل محدد فاكتبوه؛ توثيقًا للحقوق وحفظًا للأموال، وليكتب بينكم كاتب يتصف بالعدل والضبط، ولا يمتنع من علمه الله الكتابة عن كتابة ما يمليه المدين المقر بالحق متقيًا ربه دون نقص، فإن عجز أملّ وليه بالعدل، واشهدوا على ذلك شاهدين عدلين لحفظ الحقوق.'
        : 'الله الذي لا إله بحق إلا هو، المتصف بالحياة الكاملة الدائمة والقيومية التامة على جميع خلقه تدبيرًا وحفظًا، لا تأخذه سِنَةٌ ولا نوم.',
      tafsirEn: isLongest
        ? 'O you who have believed, when you enter into a debt agreement for a stated period, commit it to writing for clarity and peace of mind. An honest scribe should record the exact terms as dictated by the indebted party fearing Allah, supported by trustworthy witnesses to uphold justice.'
        : 'The verse affirms that Allah alone is the true God worthy of worship, possessing complete everlasting life, and sustaining all creation without fatigue or slumber.',
      tafsirNameAr: 'التفسير الميسر',
      tafsirNameEn: 'Al-Muyassar',
      audioUrl: getAyahAudioUrl(surah, ayah)
    };
  }

  const key = `quran:${surah}:${ayah}`;
  return cached(key, async () => {
    const [arRes, saheehRes, moyassarRes, mokhtasarRes] = await Promise.allSettled([
      fetchJson(`https://api.alquran.cloud/v1/ayah/${surah}:${ayah}/quran-uthmani-quran-academy`, { timeout: 5000 }),
      fetchJson(`https://quranenc.com/api/v1/translation/aya/english_saheeh/${surah}/${ayah}`, { timeout: 5000 }),
      fetchJson(`https://quranenc.com/api/v1/translation/aya/arabic_moyassar/${surah}/${ayah}`, { timeout: 5000 }),
      fetchJson(`https://quranenc.com/api/v1/translation/aya/english_mokhtasar/${surah}/${ayah}`, { timeout: 5000 })
    ]);

    const arText = arRes.status === 'fulfilled' && arRes.value?.data?.text ? arRes.value.data.text : null;
    const globalNumber = arRes.status === 'fulfilled' && arRes.value?.data?.number ? arRes.value.data.number : null;

    const translation = saheehRes.status === 'fulfilled' && saheehRes.value?.result?.translation
      ? cleanHtml(saheehRes.value.result.translation)
      : '';

    const tafsirAr = moyassarRes.status === 'fulfilled' && moyassarRes.value?.result?.translation
      ? cleanHtml(moyassarRes.value.result.translation)
      : 'تفسير الآية الكريمة من التفسير الميسر';

    const tafsirEn = mokhtasarRes.status === 'fulfilled' && mokhtasarRes.value?.result?.translation
      ? cleanHtml(mokhtasarRes.value.result.translation)
      : (translation || 'English translation and summary of the noble verse.');

    return {
      surah,
      ayah,
      globalNumber: globalNumber || ayah,
      arabic: arText || 'بِسْمِ ٱللَّهِ ٱلرَّحْمَـٰنِ ٱلرَّحِيمِ',
      surahArabic: surahMeta.nameAr,
      surahEnglish: surahMeta.nameEn,
      revelationType: surahMeta.type === 'مَدَنِيَّة' ? 'Medinan' : 'Meccan',
      revelationTypeAr: surahMeta.type,
      totalAyahs: surahMeta.ayahs,
      translation,
      tafsirAr,
      tafsirEn,
      tafsirNameAr: 'التفسير الميسر',
      tafsirNameEn: 'Al-Muyassar',
      audioUrl: getAyahAudioUrl(surah, ayah)
    };
  // Verse text/translations/tafsir are immutable: cache 30 days to cut data
  // use. Dynamic data (prayer/weather, date-keyed or 24h TTL) is unaffected.
  }, 30 * 24 * 60 * 60 * 1000);
}

function normalizeCapital(c) {
  // Data file is the authoritative roster for this broadcast; no runtime country API calls are needed.
  return {
    code: c.code,
    name: c.name,
    nameAr: c.nameAr || c.name,
    capital: c.capital,
    capitalAr: c.capitalAr || c.capital,
    capitalNote: c.capitalNote || '',
    lat: Number(c.lat),
    lon: Number(c.lon),
    timezone: c.timezone,
    flag: c.flag,
    prayerMethod: c.prayerMethod,
    prayerMadhab: c.prayerMadhab
  };
}

const capitals = JSON.parse(fs.readFileSync(path.join(ROOT, 'countries.json'), 'utf8')).map(normalizeCapital);

// Display order: Arab League first (Makkah first), then other Muslim-majority
// countries, then the rest grouped by continent (from timezone) and alphabetical.
// Applied once at load so every rotation page follows it globally.
const ARAB_LEAGUE = ['SA', 'YE', 'AE', 'QA', 'BH', 'KW', 'OM', 'IQ', 'SY', 'JO', 'LB', 'PS', 'EG', 'SD', 'LY', 'TN', 'DZ', 'MA', 'MR', 'SO', 'DJ', 'KM'];
const MUSLIM_MAJORITY = ['TR', 'IR', 'AF', 'PK', 'BD', 'MY', 'ID', 'BN', 'UZ', 'TM', 'KG', 'KZ', 'TJ', 'AZ', 'SN', 'ML', 'NE', 'TD', 'NG', 'BF', 'CI', 'GN', 'GW', 'SL', 'GM', 'AL', 'BA', 'MV'];
const CONTINENT_ORDER = { Asia: 0, Africa: 1, Europe: 2, America: 3, Australia: 4, Pacific: 4, Atlantic: 5, Indian: 5, Arctic: 5, Antarctica: 5, Etc: 6 };
function tzContinent(tz) {
  const z = String(tz || '');
  const i = z.indexOf('/');
  const k = i < 0 ? 'Etc' : z.slice(0, i);
  return CONTINENT_ORDER[k] !== undefined ? CONTINENT_ORDER[k] : 6;
}
function countryRank(c) {
  let i = ARAB_LEAGUE.indexOf(c.code);
  if (i >= 0) return [0, i];
  i = MUSLIM_MAJORITY.indexOf(c.code);
  if (i >= 0) return [1, i];
  return [2, tzContinent(c.timezone)];
}
capitals.sort((a, b) => {
  const ra = countryRank(a), rb = countryRank(b);
  if (ra[0] !== rb[0]) return ra[0] - rb[0];
  if (ra[1] !== rb[1]) return ra[1] - rb[1];
  return String(a.nameAr || a.name || '').localeCompare(String(b.nameAr || b.name || ''), 'ar');
});

async function countrySnapshot(c) {
  const base = normalizeCapital(c);
  const weatherResult = await weather(base).catch(() => null);
  const enriched = { ...base, timezone: weatherResult?.timezone || base.timezone };
  const prayerResult = await verifiedPrayer(enriched).catch(() => ({ timings: null, verification: { status: 'unavailable' } }));
  return {
    ...enriched,
    weather: weatherResult,
    prayer: prayerResult,
    refreshedAt: new Date().toISOString()
  };
}

async function capitalsPage(url) {
  const requested = Number(url.searchParams.get('page') || 0);
  const size = Math.min(Math.max(Number(url.searchParams.get('size') || 6), 1), 18);
  const totalPages = Math.ceil(capitals.length / size);
  const page = ((requested % totalPages) + totalPages) % totalPages;
  const slice = capitals.slice(page * size, page * size + size);
  const data = await Promise.all(slice.map(countrySnapshot));
  return {
    page,
    size,
    total: capitals.length,
    totalPages,
    cities: data,
    generatedAt: new Date().toISOString()
  };
}

const routes = {
  '/api/health': async () => ({ ok: true, service: 'quran-live-stream-web', now: new Date().toISOString(), capitals: capitals.length, surahs: surahsData.length, cacheEntries: cache.size, cacheLimit: CACHE_MAX_ENTRIES }),
  '/api/capitals': capitalsPage,
  '/api/surahs': async () => surahsData,
  '/api/quran': async url => {
    const surah = Number(url.searchParams.get('surah') || 1);
    const ayah = Number(url.searchParams.get('ayah') || 1);
    const verse = await quranVerse(surah, ayah);
    // Resolve audio at response time so a file downloaded after the text was
    // cached is immediately promoted to the local path on subsequent loops.
    return { ...verse, audioUrl: getAyahAudioUrl(surah, ayah) };
  },
  '/api/city': async url => {
    const code = (url.searchParams.get('code') || 'TR').toUpperCase();
    const found = capitals.find(x => x.code === code);
    if (!found) throw new Error('Unknown capital code');
    return countrySnapshot(found);
  }
};

const server = http.createServer(async (req, res) => {
  try {
    const u = new URL(req.url, `http://${req.headers.host}`);
    if (routes[u.pathname]) return json(res, await routes[u.pathname](u));
    const file = u.pathname === '/' ? 'index.html' : u.pathname.replace(/^\//, '');
    const fp = path.resolve(ROOT, file);
    if (!fp.startsWith(path.resolve(ROOT))) return json(res, { error: 'forbidden' }, 403);
    if (!fs.existsSync(fp) || fs.statSync(fp).isDirectory()) return json(res, { error: 'not found' }, 404);
    const ext = path.extname(fp);
    const types = {
      '.html': 'text/html; charset=utf-8',
      '.js': 'text/javascript; charset=utf-8',
      '.css': 'text/css; charset=utf-8',
      '.json': 'application/json; charset=utf-8',
      '.jpg': 'image/jpeg',
      '.png': 'image/png',
      '.svg': 'image/svg+xml',
      '.woff2': 'font/woff2',
      '.woff': 'font/woff',
      '.ttf': 'font/ttf',
      '.mp3': 'audio/mpeg'
    };
    const isImmutable = ['.woff2', '.woff', '.ttf', '.mp3', '.jpg', '.png'].includes(ext);
    res.writeHead(200, {
      'Content-Type': types[ext] || 'application/octet-stream',
      'Cache-Control': ext === '.json' ? 'no-cache' : (isImmutable ? 'public, max-age=86400' : 'public, max-age=300')
    });
    fs.createReadStream(fp).pipe(res);
  } catch (e) {
    console.error(e);
    json(res, { error: e.message }, 502);
  }
});

// Retry on EADDRINUSE instead of crashing: under load the old instance may
// still be releasing the port when the watchdog launches a replacement.
server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    console.error(`Port ${PORT} busy, retrying in 3s...`);
    setTimeout(() => server.listen(PORT, '127.0.0.1'), 3000);
  } else {
    throw e;
  }
});
server.listen(PORT, '127.0.0.1', () => console.log(`Quran24/7 web ${PORT}`));
