#!/usr/bin/env node
// ==============================================================================
// QuranLiveStream — strict quality assurance gates
// Dataset integrity + native multi-platform layout/encoder architecture + APIs.
// ==============================================================================
const fs = require('fs');
const path = require('path');
const http = require('http');
const { spawn } = require('child_process');
const ROOT = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(ROOT, p), 'utf8');
const assert = (ok, msg) => { if (!ok) { console.error(`❌ QA ERROR: ${msg}`); throw new Error(msg); } };
console.log('🔍 Starting QuranLiveStream strict quality gates...\n');

// 1) Complete country dataset.
const countriesPath = path.join(ROOT, 'web', 'countries.json');
assert(fs.existsSync(countriesPath), 'web/countries.json not found');
const countries = JSON.parse(fs.readFileSync(countriesPath, 'utf8'));
assert(countries.length === 195, `Expected 195 countries, got ${countries.length}`);
assert(new Set(countries.map(c => c.code)).size === 195, 'Duplicate country code found');
for (const c of countries) {
  for (const k of ['code','name','nameAr','capital','capitalAr','lat','lon','timezone','flag']) assert(c[k], `${c.code}: missing ${k}`);
  assert(Math.abs(Number(c.lat)) <= 90 && Math.abs(Number(c.lon)) <= 180, `${c.code}: invalid coordinates`);
}
console.log('✓ Gate 1: 195-country dataset verified.');

// 2) Canonical Surah roster.
const surahs = JSON.parse(read('web/surahs.json'));
assert(surahs.length === 114, `Expected 114 Surahs, got ${surahs.length}`);
let ayahs = 0;
surahs.forEach((s, i) => {
  assert(s.number === i + 1, `Surah order mismatch at ${i}`);
  assert(s.nameAr && s.nameEn && s.ayahs > 0, `Surah ${s.number} metadata incomplete`);
  assert(s.type === 'مَكِّيَّة' || s.type === 'مَدَنِيَّة', `Surah ${s.number}: invalid revelation type`);
  ayahs += s.ayahs;
});
assert(ayahs === 6236, `Expected 6,236 Ayahs, got ${ayahs}`);
console.log('✓ Gate 2: 114 Surahs / 6,236 Ayahs verified.');

// 3) Frontend + exact native aspect architecture.
const index = read('web/index.html');
const app = read('web/app.js');
const baseCss = read('web/style.css');
const platformCss = read('web/platform.css');
const platformJs = read('web/platform-layout.js');
assert(index.includes('platform.css') && index.includes('platform-layout.js'), 'Native platform layout assets are not loaded');
assert(index.includes('reciter-pill') && index.includes('surah-ayah-pill') && index.includes('tafsir-info-pill'), 'Broadcast info pills missing');
assert(app.includes('fitElement') && app.includes('fitAllContent'), 'Dynamic typography fitting missing');
assert(app.includes('playRecitation') && app.includes('advanceToNextAyah'), 'Recitation synchronizer missing');
assert(baseCss.includes('active-next') && baseCss.includes('eqPulse'), 'Core broadcast visual states missing');
for (const layout of ['landscape','portrait','square']) {
  assert(platformCss.includes(`data-layout="${layout}"`), `Missing ${layout} native CSS layout`);
}
assert(platformJs.includes('--portrait-city-rows') && platformJs.includes('--square-city-rows'), 'Dynamic platform grid sizing missing');
console.log('✓ Gate 3: responsive native 16:9 / 9:16 / 1:1 UI verified.');

// 4) Universal streaming/resource architecture.
const required = [
  'scripts/hardware_profile.sh','scripts/benchmark_host.sh','scripts/platforms.sh','scripts/stream_plan.sh',
  'scripts/stream_multi.sh','scripts/stream_worker.sh','scripts/broadcast_ui_group.sh','scripts/resource_governor.sh',
  'scripts/preflight.sh','scripts/watchdog.sh','scripts/maintenance.sh','scripts/setup_cron.sh','scripts/control.sh',
  'scripts/stream_youtube.sh','scripts/stream_tiktok.sh','scripts/stream_dual.sh','systemd/quran-live.service',
  'systemd/quran-live-governor.service'
];
required.forEach(p => assert(fs.existsSync(path.join(ROOT, p)), `Required file ${p} missing`));
const platforms = read('scripts/platforms.sh');
const planner = read('scripts/stream_plan.sh');
const master = read('scripts/stream_multi.sh');
const worker = read('scripts/stream_worker.sh');
const governor = read('scripts/resource_governor.sh');
const bench = read('scripts/benchmark_host.sh');
const service = read('systemd/quran-live.service');
const serverCode = read('web/server.js');
assert(platforms.includes('quran_profile_dimensions') && platforms.includes('quran_target_layout'), 'Platform capability/native dimension registry missing');
assert(platforms.includes('portrait') && platforms.includes('square') && platforms.includes('landscape'), 'Aspect families incomplete');
assert(planner.includes('QUALITY_POLICY') && planner.includes('stream_plan.tsv'), 'Adaptive stream planner missing');
assert(master.includes('stream_plan.sh') && master.includes('stream_worker.sh'), 'Universal coordinated worker orchestration missing');
// Strip comments before checking that geometry-changing FFmpeg filters cannot sneak into worker code.
const workerCode = worker.split('\n').filter(l => !/^\s*#/.test(l)).join('\n');
assert(!/(^|[,=:])\s*(scale|crop|pad)\s*=/.test(workerCode), 'Forbidden FFmpeg geometry filter found in native worker');
assert(worker.includes('-video_size "${STREAM_WIDTH}x${STREAM_HEIGHT}"'), 'x11 capture is not bound to final native dimensions');
assert(governor.includes('RESOURCE_CPU_HARD') && governor.includes('slowest_speed') && governor.includes('minimum floor'), 'Global resource governor safeguards incomplete');
assert(service.includes('CPUQuota=@CPU_QUOTA@') && service.includes('MemoryHigh=88%'), 'systemd resource envelope missing');
assert(bench.includes('HOST_HW_1440') && bench.includes('HOST_HW_4K'), 'Progressive high-resolution benchmark gates missing');
assert(serverCode.includes('CACHE_MAX_ENTRIES') && serverCode.includes('rememberCache'), 'Bounded in-memory API cache missing');
assert(serverCode.includes('audioInflight') && serverCode.includes('AbortSignal.timeout(15000)'), 'Deduplicated bounded audio caching safeguards missing');
console.log('✓ Gate 4: native multi-platform planner, encoder, governor and safety envelope verified.');

// Offline assets.
assert(fs.existsSync(path.join(ROOT, 'web', 'assets', 'fonts', 'fonts.css')), 'Local fonts.css missing');
const bg = fs.statSync(path.join(ROOT, 'web', 'assets', 'background.jpg'));
assert(bg.size < 1.5 * 1024 * 1024, `Background too large (${(bg.size/1024/1024).toFixed(2)}MB)`);

// 5) Integration test local server/API fixtures.
const port = 8899;
const server = spawn(process.execPath, ['web/server.js'], {
  cwd: ROOT,
  env: { ...process.env, PORT: String(port), QURAN_OFFLINE: '1', CACHE_MAX_ENTRIES: '96' },
  stdio: 'ignore'
});
function getJson(url) {
  return new Promise((resolve, reject) => {
    http.get(url, res => {
      let body = ''; res.setEncoding('utf8'); res.on('data', d => body += d);
      res.on('end', () => { try { resolve({ status: res.statusCode, data: JSON.parse(body) }); } catch { resolve({ status: res.statusCode, raw: body }); } });
    }).on('error', reject);
  });
}
(async () => {
  try {
    for (let i = 0; i < 40; i++) {
      try { const r = await getJson(`http://127.0.0.1:${port}/api/health`); if (r.status === 200) break; } catch {}
      await new Promise(r => setTimeout(r, 100));
    }
    const health = await getJson(`http://127.0.0.1:${port}/api/health`);
    assert(health.status === 200 && health.data.ok === true, 'Health endpoint failed');
    assert(health.data.cacheLimit === 96, `Cache limit override failed (${health.data.cacheLimit})`);
    assert(health.data.cacheEntries <= health.data.cacheLimit, 'In-memory cache exceeds configured limit');
    const sr = await getJson(`http://127.0.0.1:${port}/api/surahs`);
    assert(sr.status === 200 && sr.data.length === 114, 'Surahs endpoint failed');
    const capitals = await getJson(`http://127.0.0.1:${port}/api/capitals?page=0&size=5`);
    assert(capitals.status === 200 && capitals.data.cities.length === 5 && capitals.data.total === 195, 'Capitals endpoint failed');
    const oneCity = await getJson(`http://127.0.0.1:${port}/api/capitals?page=0&size=1`);
    assert(oneCity.status === 200 && oneCity.data.size === 1 && oneCity.data.cities.length === 1, 'One-city governor emergency floor failed');
    const q282 = await getJson(`http://127.0.0.1:${port}/api/quran?surah=2&ayah=282`);
    assert(q282.status === 200 && q282.data.ayah === 282, 'Longest Ayah fixture failed');
    assert(q282.data.arabic && q282.data.translation && q282.data.tafsirAr && q282.data.tafsirEn, 'Longest Ayah fields incomplete');
    assert(q282.data.audioUrl && q282.data.audioUrl.endsWith('002282.mp3'), '2:282 audio URL invalid');
    const q1 = await getJson(`http://127.0.0.1:${port}/api/quran?surah=1&ayah=1`);
    assert(q1.status === 200 && q1.data.audioUrl.endsWith('001001.mp3'), '1:1 fixture/audio failed');
    console.log('✓ Gate 5: local server/API fixtures verified.');
    console.log('\n🎉 ALL 5 QUALITY GATES PASSED.');
    process.exit(0);
  } finally { server.kill('SIGTERM'); }
})().catch(err => {
  console.error('\n❌ QA SUITE FAILED:', err.message);
  try { server.kill('SIGTERM'); } catch {}
  process.exit(1);
});
