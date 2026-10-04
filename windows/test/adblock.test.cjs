'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createBlocker } = require('../lib/adblock.cjs');

const block = (pattern, trigger = {}) => ({ trigger: { 'url-filter': pattern, ...trigger }, action: { type: 'block' } });
const allow = (pattern, trigger = {}) => ({ trigger: { 'url-filter': pattern, ...trigger }, action: { type: 'ignore-previous-rules' } });
const hide = (selector, trigger = {}) => ({ trigger: { 'url-filter': '.*', ...trigger }, action: { type: 'css-display-none', selector } });
function fixture(t, rules, initial = { adblockEnabled: true, adblockMode: 'on' }, initialTop = 'https://news.example.com/') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'breeze-adblock-'));
  const rulesPath = path.join(dir, 'rules.json');
  fs.writeFileSync(rulesPath, JSON.stringify(rules));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  let settings = initial, top = initialTop;
  const blocker = createBlocker({ rulesPath, getSettings: () => settings, getTopURL: () => top });
  return {
    blocker, rulesPath,
    settings: value => { settings = value; }, top: value => { top = value; },
    request: (url, resourceType = 'script', extra = {}) => blocker.shouldBlock({ url, resourceType, ...extra }),
  };
}

test('blocking defaults off and respects explicit disabled/off settings', t => {
  const f = fixture(t, [block('blocked')], {});
  assert.equal(f.request('https://tracker.test/blocked'), false);
  assert.equal(f.blocker.cosmeticCSS('https://example.com/'), '');
  f.settings({ adblockMode: 'on' });
  assert.equal(f.request('https://tracker.test/blocked'), false);
  f.settings({ adblockEnabled: false, adblockMode: 'advanced' });
  assert.equal(f.request('https://tracker.test/blocked'), false);
  f.settings({ adblockEnabled: true, adblockMode: 'off' });
  assert.equal(f.request('https://tracker.test/blocked'), false);
  f.settings({ adblockEnabled: true, adblockMode: 'on' });
  assert.equal(f.request('https://tracker.test/blocked'), true);
});

test('site exceptions override list and native rules, cover subdomains, and are label-bounded', t => {
  const f = fixture(t, [block('blocked')], { adblockEnabled: true, adblockSiteExceptions: [' Example.COM '] });
  assert.equal(f.request('https://tracker.test/blocked'), false);
  assert.equal(f.request('https://doubleclick.net/ad.js'), false);
  f.top('https://deep.news.example.com/');
  assert.equal(f.request('https://tracker.test/blocked'), false);
  f.top('https://notexample.com/');
  assert.equal(f.request('https://tracker.test/blocked'), true);
  f.top('https://example.com.evil.test/');
  assert.equal(f.request('https://tracker.test/blocked'), true);
  // Settings are read for each decision, not frozen during compilation.
  f.settings({ adblockEnabled: true, adblockSiteExceptions: ['https://notexample.com/'] });
  f.top('https://notexample.com/');
  assert.equal(f.request('https://tracker.test/blocked'), false);
});

test('main-frame navigation evaluates the destination, not a stale old top URL', t => {
  const f = fixture(t, [block('blocked')], { adblockEnabled: true, adblockSiteExceptions: ['allowed.test'] });
  assert.equal(f.request('https://allowed.test/blocked', 'mainFrame'), false);
  f.top('https://allowed.test/');
  assert.equal(f.request('https://denied.test/blocked', 'mainFrame'), true);
});

test('first/third-party matching uses the public suffix and private suffix lists', t => {
  const f = fixture(t, [block('third', { 'load-type': ['third-party'] }), block('first', { 'load-type': ['first-party'] })]);
  assert.equal(f.request('https://static.example.com/third'), false);
  assert.equal(f.request('https://static.example.com/first'), true);
  assert.equal(f.request('https://example.net/third'), true);
  assert.equal(f.request('https://example.net/first'), false);
  f.top('https://www.publisher.co.uk/');
  assert.equal(f.request('https://cdn.publisher.co.uk/third'), false);
  assert.equal(f.request('https://other.co.uk/third'), true);
  f.top('https://alice.github.io/');
  assert.equal(f.request('https://bob.github.io/third'), true);
  assert.equal(f.request('https://alice.github.io/first'), true);
  f.top('http://127.0.0.1:8000/');
  assert.equal(f.request('http://127.0.0.1:9000/first'), true);
  assert.equal(f.request('http://127.0.0.2:8000/third'), true);
});

test('if-domain is exact unless prefixed with *, and unless-domain excludes context', t => {
  const f = fixture(t, [
    block('/exact', { 'if-domain': ['example.com'] }),
    block('/wild', { 'if-domain': ['*example.com'] }),
    block('/unless', { 'unless-domain': ['*example.com'] }),
  ]);
  assert.equal(f.request('https://tracker.test/exact'), false);
  assert.equal(f.request('https://tracker.test/wild'), true);
  assert.equal(f.request('https://tracker.test/unless'), false);
  f.top('https://example.com/');
  assert.equal(f.request('https://tracker.test/exact'), true);
  f.top('https://other.test/');
  assert.equal(f.request('https://tracker.test/wild'), false);
  assert.equal(f.request('https://tracker.test/unless'), true);
});

test('resource filters map Chromium network request types precisely', t => {
  const cases = [['script', 'script'], ['style-sheet', 'stylesheet'], ['image', 'image'], ['font', 'font'], ['fetch', 'xhr'], ['media', 'media'], ['websocket', 'webSocket'], ['ping', 'ping'], ['top-document', 'mainFrame'], ['child-document', 'subFrame'], ['other', 'other']];
  const rules = cases.map(([wk], i) => block(`/type${i}$`, { 'resource-type': [wk] }));
  const f = fixture(t, rules);
  for (let i = 0; i < cases.length; i++) {
    assert.equal(f.request(`https://resources.test/type${i}`, cases[i][1]), true, cases[i][0]);
    assert.equal(f.request(`https://resources.test/type${i}`, cases[i][1] === 'image' ? 'script' : 'image'), false, `${cases[i][0]} mismatch`);
  }
});

test('popup rules require the explicit popup signal and never broaden to all documents', t => {
  const f = fixture(t, [block('popup', { 'resource-type': ['popup'] })]);
  assert.equal(f.request('https://ads.test/popup', 'mainFrame'), false);
  assert.equal(f.request('https://ads.test/popup', 'mainFrame', { isPopup: true }), true);
  assert.equal(f.blocker.stats.popupRules, 1);
});

test('popup party/domain rules use the opener context', t => {
  const f = fixture(t, [block('popup', { 'resource-type': ['popup'], 'load-type': ['third-party'], 'if-domain': ['*example.com'] })]);
  assert.equal(f.request('https://ads.test/popup', 'mainFrame', { isPopup: true }), true);
  assert.equal(f.request('https://cdn.example.com/popup', 'mainFrame', { isPopup: true }), false);
  f.top('https://elsewhere.test/');
  assert.equal(f.request('https://ads.test/popup', 'mainFrame', { isPopup: true }), false);
});

test('ignore-previous-rules preserves list order, including later block rules', t => {
  const f = fixture(t, [block('/ad'), allow('/ad/allowed'), block('/ad/allowed/blocked-again')]);
  assert.equal(f.request('https://cdn.test/ad'), true);
  assert.equal(f.request('https://cdn.test/ad/allowed'), false);
  assert.equal(f.request('https://cdn.test/ad/allowed/blocked-again'), true);
});

test('Threads CDN exception is limited to Threads top-level sites', t => {
  const f = fixture(t, [block('cdnthreads\\.com')]);
  assert.equal(f.request('https://media.cdnthreads.com/video.mp4', 'media'), true);
  f.top('https://www.threads.com/');
  assert.equal(f.request('https://media.cdnthreads.com/video.mp4', 'media'), false);
  assert.equal(f.request('https://media.cdnthreads.com/image.gif', 'image'), false);
  f.top('https://notthreads.com/');
  assert.equal(f.request('https://media.cdnthreads.com/video.mp4', 'media'), true);
});

test('native extra tracker rules are third-party only', t => {
  const f = fixture(t, []);
  assert.equal(f.request('https://pagead2.googlesyndication.com/pagead.js'), true);
  assert.equal(f.request('https://doubleclick.net/ads'), true);
  f.top('https://doubleclick.net/');
  assert.equal(f.request('https://securepubads.g.doubleclick.net/ads'), false);
});

test('on mode includes bundled cosmetics; advanced/extreme add native selectors', t => {
  const f = fixture(t, [hide('.advert'), hide('#only-news', { 'if-domain': ['*news.test'] })]);
  const on = f.blocker.cosmeticCSS('https://news.test/');
  assert.match(on, /\.advert\{display:none!important;\}/);
  assert.match(on, /#only-news/);
  assert.doesNotMatch(on, /data-ad/);
  assert.doesNotMatch(f.blocker.cosmeticCSS('https://elsewhere.test/'), /#only-news/);
  f.settings({ adblockEnabled: true, adblockMode: 'advanced' });
  assert.match(f.blocker.cosmeticCSS('https://news.test/'), /data-ad/);
  f.settings({ adblockEnabled: true, adblockMode: 'extreme' });
  assert.match(f.blocker.cosmeticCSS('https://news.test/'), /data-ad/);
  f.settings({ adblockEnabled: true, adblockMode: 'advanced', adblockSiteExceptions: ['news.test'] });
  assert.equal(f.blocker.cosmeticCSS('https://news.test/'), '');
  assert.equal(f.blocker.cosmeticCSS('https://sub.news.test/'), '');
  f.settings({ adblockEnabled: false });
  assert.equal(f.blocker.cosmeticCSS('https://news.test/'), '');
});

test('cosmetic exceptions clear preceding selectors but preserve later selectors', t => {
  const f = fixture(t, [hide('.before'), allow('/allowed'), hide('.after')]);
  assert.match(f.blocker.cosmeticCSS('https://example.com/normal'), /\.before/);
  const css = f.blocker.cosmeticCSS('https://example.com/allowed');
  assert.doesNotMatch(css, /\.before/);
  assert.match(css, /\.after/);
});

test('invalid/unsupported rules are skipped individually without broadening', t => {
  const f = fixture(t, [
    block('['), block('unsupported', { 'if-top-url': ['https://only.test'] }),
    block('unsupported', { 'resource-type': ['imaginary'] }),
    block('unsupported', { 'load-type': ['imaginary'] }),
    block('unsupported', { 'if-domain': ['*'] }),
    { trigger: { 'url-filter': 'unsupported' }, action: { type: 'make-https' } },
    hide('.bad{background:url(https://bad.test)}'),
    hide('.bad/*comment*/'), block('valid'),
  ]);
  assert.equal(f.blocker.stats.skippedRules, 8);
  assert.equal(f.request('https://example.test/unsupported'), false);
  assert.equal(f.request('https://example.test/valid'), true);
  assert.equal(f.blocker.cosmeticCSS('https://example.test/'), '');
});

test('unavailable or invalid rules fail open without throwing', t => {
  const f = fixture(t, []);
  fs.writeFileSync(f.rulesPath, 'not json');
  for (const rulesPath of [f.rulesPath, `${f.rulesPath}.missing`]) {
    const blocker = createBlocker({ rulesPath, getSettings: () => ({ adblockEnabled: true }) });
    assert.equal(blocker.stats.loaded, false);
    assert.equal(typeof blocker.error, 'string');
    assert.equal(blocker.shouldBlock({ url: 'https://doubleclick.net/ads', resourceType: 'script' }), false);
    assert.equal(blocker.cosmeticCSS('https://example.com/'), '');
  }
});

test('missing page context fails open for constrained rules and site exceptions', t => {
  const f = fixture(t, [block('third', { 'load-type': ['third-party'] }), block('scoped', { 'if-domain': ['*example.com'] }), block('unless', { 'unless-domain': ['*example.com'] }), block('plain')]);
  f.top('');
  for (const suffix of ['third', 'scoped', 'unless']) assert.equal(f.request(`https://example.test/${suffix}`), false);
  assert.equal(f.request('https://example.test/plain'), true);
  f.settings({ adblockEnabled: true, adblockSiteExceptions: ['example.com'] });
  assert.equal(f.request('https://example.test/plain'), false);
});

test('non-web schemes, malformed URLs, and failing settings callbacks are allowed', t => {
  const f = fixture(t, [block('.*')]);
  for (const url of ['file:///ad', 'breeze://settings', 'chrome://settings', 'data:text/html,ad', 'not a URL']) assert.equal(f.request(url), false);
  const blocker = createBlocker({ rulesPath: f.rulesPath, getSettings: () => { throw new Error('unavailable'); } });
  assert.equal(blocker.shouldBlock({ url: 'https://example.com/' }), false);
  assert.equal(blocker.cosmeticCSS('https://example.com/'), '');
});

test('indexing preserves optional atoms, grouping, alternation, escapes, and case sensitivity', t => {
  const patterns = ['abc?', 'hello(?:optional)?world', 'foo|bar', '(?:aaa|bbb)tail', 'ab{0,2}c', 'ab+c', '\\x61bc', '\\d+track', 'hello\\?ad=1', '^https?://cdn\\.test/CaseSensitive$'];
  const urls = ['https://test.test/ab', 'https://test.test/abc', 'https://test.test/helloworld', 'https://test.test/foo', 'https://test.test/bar', 'https://test.test/bbbtail', 'https://test.test/ac', 'https://test.test/abbbc', 'https://test.test/123track', 'https://test.test/hello?ad=1', 'https://cdn.test/CaseSensitive', 'https://cdn.test/casesensitive', 'https://test.test/clean'];
  for (const pattern of patterns) {
    const rule = block(pattern, { 'url-filter-is-case-sensitive': true });
    const f = fixture(t, [rule]);
    const reference = new RegExp(pattern);
    for (const url of urls) assert.equal(f.request(url), reference.test(new URL(url).href), `${pattern}: ${url}`);
  }
});

test('bundled EasyList is indexed and blocks known ads without scanning 100k regexes', t => {
  const rulesPath = path.join(__dirname, '../../native/easylist.json');
  if (!fs.existsSync(rulesPath)) { t.skip('Source checkout fixture unavailable'); return; }
  const blocker = createBlocker({ rulesPath, getSettings: () => ({ adblockEnabled: true }), getTopURL: () => 'https://news.example.com/' });
  assert.equal(blocker.stats.loaded, true);
  assert.ok(blocker.stats.totalRules > 100000);
  assert.ok(blocker.stats.indexedRules > 100000);
  assert.ok(blocker.stats.fallbackRules < 100);
  assert.equal(blocker.shouldBlock({ url: 'https://doubleclick.net/ads', resourceType: 'script' }), true);
  assert.equal(blocker.shouldBlock({ url: 'https://www.example.com/assets/application.js', resourceType: 'script' }), false);
  assert.ok(blocker.stats.lastCandidates < 2000, `${blocker.stats.lastCandidates} candidates`);
  assert.ok(blocker.stats.lastRegexTests < 100, `${blocker.stats.lastRegexTests} regex tests`);
});
