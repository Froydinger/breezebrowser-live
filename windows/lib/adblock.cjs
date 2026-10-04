'use strict';

const fs = require('node:fs');
const { getDomain } = require('tldts');

/**
 * Local WebKit-content-rule adapter for Chromium. Uses the SAME bundled JSON as
 * native/Sources/Breeze/AdBlocker.swift; it never downloads a filter list.
 *
 * Supported: ordered block / ignore-previous-rules / css-display-none actions;
 * URL regular expressions (case-insensitive by default); if/unless-domain;
 * first/third-party load types; Chromium equivalents of bundled resource types.
 * Registrable domains use the Public Suffix List (including private suffixes).
 * "popup" requires details.isPopup=true: Electron webRequest does not distinguish
 * popup documents itself. The caller must pass that signal if desired. Other
 * unsupported triggers/actions, invalid patterns and unsafe CSS selectors are
 * skipped, rather than accidentally broadening a rule. Stats expose that count.
 * JavaScript's regex engine is used for WebKit's common regex subset. The current
 * bundled list compiles completely; this is not a general ABP/uBlock engine.
 *
 * Every regex gets a provably mandatory literal where possible. A rare-trigram
 * index finds candidates, followed by a literal check and the original regex.
 * Rules without a usable literal are the small fallback set, NOT 100k regexes
 * per request. Exceptions retain their original sequence even after indexing.
 *
 * Missing/invalid settings, absent list files, and unknown context for contextual
 * rules fail open. Blocking must be explicitly enabled. Site exceptions include
 * subdomains and override every rule. cosmeticCSS is optional: inject its return
 * value using webContents.insertCSS, and remove old CSS on setting changes.
 */

const ACTIONS = new Set(['block', 'ignore-previous-rules', 'css-display-none']);
const TRIGGERS = new Set(['url-filter', 'url-filter-is-case-sensitive', 'if-domain', 'unless-domain', 'load-type', 'resource-type']);
const RESOURCE_TYPES = new Set(['document', 'top-document', 'child-document', 'image', 'style-sheet', 'script', 'font', 'raw', 'fetch', 'media', 'svg-document', 'popup', 'ping', 'websocket', 'other']);
const RESOURCE_MAP = {
  mainframe: ['document', 'top-document'], subframe: ['document', 'child-document'],
  stylesheet: ['style-sheet'], script: ['script'], image: ['image'], font: ['font'],
  xhr: ['fetch', 'raw'], fetch: ['fetch', 'raw'], media: ['media'],
  websocket: ['websocket'], ping: ['ping'], cspreport: ['ping'],
  object: ['other'], other: ['other'],
};
const EXTRA_DOMAINS = ['doubleclick.net', 'googlesyndication.com', 'securepubads.g.doubleclick.net', 'googleadservices.com', 'amazon-adsystem.com', 'taboola.com', 'outbrain.com', 'adnxs.com', 'rubiconproject.com', 'pubmatic.com', 'scorecardresearch.com', 'criteo.com', 'media.net', 'ads.yahoo.com', 'adtech.yahooinc.com', 'gemini.yahoo.com'];
const ADVANCED_SELECTORS = "[id^='google_ads'],[id*='google_ads'],[id*='ad-container'],[class*='ad-container'],[class*='ad_unit'],[class*='ad-slot'],[class*='advertisement'],[data-ad],[data-testid*='ad']";

function parseURL(value) {
  try {
    const url = new URL(value);
    return /^(https?|wss?):$/.test(url.protocol) ? url : null;
  } catch { return null; }
}
function hostname(value) { return value.toLowerCase().replace(/\.$/, ''); }
function siteDomain(host) { return getDomain(host, { allowPrivateDomains: true }) || host; }
function isSubdomain(host, domain) { return host === domain || host.endsWith(`.${domain}`); }
function domainMatches(host, pattern) {
  return pattern.startsWith('*') ? isSubdomain(host, pattern.slice(1)) : host === pattern;
}
function validStringArray(value) { return Array.isArray(value) && value.length > 0 && value.every(item => typeof item === 'string' && item.length > 0); }
function validDomains(value) {
  return validStringArray(value) && value.every(item => /^\*?(?:[a-z0-9_-]+\.)*[a-z0-9_-]+\.?$/i.test(item));
}
function normalizeException(value) {
  if (typeof value !== 'string') return null;
  const input = value.trim().replace(/^\*\.?/, '');
  if (!input) return null;
  try {
    const url = new URL(input.includes('://') ? input : `https://${input}`);
    return /^https?:$/.test(url.protocol) && !url.username && !url.password ? hostname(url.hostname) : null;
  } catch { return null; }
}

// Only literals outside groups/character classes are used. Quantified optional
// atoms are removed. Top-level alternation makes all such literals optional.
// Conservative under-indexing is fine; over-indexing would miss a real match.
function mandatoryLiteral(source) {
  let depth = 0, inClass = false, run = '', best = '';
  const flush = () => { if (run.length > best.length) best = run; run = ''; };
  for (let i = 0; i < source.length; i++) {
    const ch = source[i];
    if (ch === '\\') {
      const next = source[++i];
      if (!depth && !inClass && next && /[^a-z0-9]/i.test(next)) run += next;
      else if (!depth && !inClass) return ''; // Escape sequences may consume following characters.
      continue;
    }
    if (inClass) { if (ch === ']') inClass = false; continue; }
    if (ch === '[') { if (!depth) flush(); inClass = true; continue; }
    if (ch === '(') { if (!depth) flush(); depth++; continue; }
    if (ch === ')') { depth = Math.max(0, depth - 1); continue; }
    if (depth) continue;
    if (ch === '|') return '';
    if (ch === '*' || ch === '?') { run = run.slice(0, -1); flush(); continue; }
    if (ch === '{') {
      const quantifier = source.slice(i).match(/^\{(\d+)(?:,\d*)?\}/);
      if (quantifier) {
        if (Number(quantifier[1]) === 0) run = run.slice(0, -1);
        flush(); i += quantifier[0].length - 1; continue;
      }
      // Unrecognized braces are legal literals in some non-Unicode JS regexes.
      // Do not index this rule rather than guess another engine's semantics.
      return '';
    }
    if (ch === '.' || ch === '+' || ch === '^' || ch === '$') { flush(); continue; }
    run += ch;
  }
  flush();
  return best.toLowerCase();
}

function trigrams(value) {
  const out = new Set();
  for (let i = 0; i + 2 < value.length; i++) out.add(value.slice(i, i + 3));
  return out;
}
function appendBucket(map, key, value) {
  let bucket = map.get(key);
  if (!bucket) { bucket = []; map.set(key, bucket); }
  bucket.push(value);
}

function compileRule(input, id, stats) {
  const trigger = input?.trigger, action = input?.action;
  if (!trigger || !action || !ACTIONS.has(action.type) || Object.keys(trigger).some(key => !TRIGGERS.has(key)) || typeof trigger['url-filter'] !== 'string' || trigger['url-filter'].length === 0) return null;
  for (const key of ['if-domain', 'unless-domain']) if (key in trigger && !validDomains(trigger[key])) return null;
  if ('load-type' in trigger && (!validStringArray(trigger['load-type']) || trigger['load-type'].some(type => !['first-party', 'third-party'].includes(type)))) return null;
  if ('resource-type' in trigger && (!validStringArray(trigger['resource-type']) || trigger['resource-type'].some(type => !RESOURCE_TYPES.has(type)))) return null;
  if ('url-filter-is-case-sensitive' in trigger && typeof trigger['url-filter-is-case-sensitive'] !== 'boolean') return null;
  if (action.type === 'css-display-none' && (typeof action.selector !== 'string' || !action.selector.trim() || /[{}\u0000]/.test(action.selector) || /\/\*|\*\//.test(action.selector))) return null;
  // Validate once; instantiate/cache lazily when the indexed rule is first used.
  try { new RegExp(trigger['url-filter'], trigger['url-filter-is-case-sensitive'] ? '' : 'i'); } catch { return null; }
  const rule = {
    id, source: trigger['url-filter'], sensitive: trigger['url-filter-is-case-sensitive'] === true,
    literal: mandatoryLiteral(trigger['url-filter']), action: action.type, selector: action.selector,
    ifDomains: trigger['if-domain']?.map(hostname), unlessDomains: trigger['unless-domain']?.map(hostname),
    loads: trigger['load-type'], resources: trigger['resource-type'], regex: null,
  };
  if (rule.resources?.includes('popup')) stats.popupRules++;
  return rule;
}

function createBlocker({ rulesPath, getSettings = () => ({}), getTopURL = () => '' } = {}) {
  const stats = { loaded: false, totalRules: 0, networkRules: 0, cosmeticRules: 0, skippedRules: 0, popupRules: 0, indexedRules: 0, fallbackRules: 0, lastCandidates: 0, lastRegexTests: 0 };
  const network = [], cosmetics = [], index = new Map(), fallback = [], frequencies = new Map();
  const domainCache = new Map(), cssCache = new Map();
  let error = null;
  try {
    const inputs = JSON.parse(fs.readFileSync(rulesPath, 'utf8'));
    if (!Array.isArray(inputs)) throw new Error('Content rules must be an array');
    stats.totalRules = inputs.length;
    // Match the native Swift additions and ordering, including its site-scoped
    // cdnthreads.com exception. The native exception covers every CDN resource.
    for (const domain of EXTRA_DOMAINS) inputs.push({ trigger: { 'url-filter': `.*://([^/]+\\.)?${domain.replaceAll('.', '\\.')}\/.*`, 'load-type': ['third-party'] }, action: { type: 'block' } });
    inputs.push({ trigger: { 'url-filter': '.*://([^/]+\\.)?cdnthreads\\.com/.*', 'if-domain': ['*threads.com'] }, action: { type: 'ignore-previous-rules' } });
    for (let id = 0; id < inputs.length; id++) {
      const rule = compileRule(inputs[id], id, stats);
      if (!rule) { stats.skippedRules++; continue; }
      if (rule.action === 'css-display-none') cosmetics.push(rule);
      else {
        network.push(rule);
        if (rule.literal.length >= 3) for (const key of trigrams(rule.literal)) frequencies.set(key, (frequencies.get(key) || 0) + 1);
      }
    }
    for (const rule of network) {
      if (rule.literal.length < 3) { fallback.push(rule); continue; }
      let rarest = null, count = Infinity;
      for (const key of trigrams(rule.literal)) if (frequencies.get(key) < count) { rarest = key; count = frequencies.get(key); }
      appendBucket(index, rarest, rule);
    }
    stats.networkRules = network.length;
    stats.cosmeticRules = cosmetics.length;
    stats.indexedRules = network.length - fallback.length;
    stats.fallbackRules = fallback.length;
    stats.loaded = true;
  } catch (cause) { error = cause.message; }

  function settingsFor(url) {
    let settings;
    try { settings = getSettings(); } catch { return null; }
    if (!stats.loaded || !settings || settings.adblockEnabled !== true || settings.adblockMode === 'off') return null;
    const exceptions = Array.isArray(settings.adblockSiteExceptions) ? settings.adblockSiteExceptions.map(normalizeException).filter(Boolean) : [];
    if (exceptions.length && (!url || exceptions.some(domain => isSubdomain(hostname(url.hostname), domain)))) return null;
    return { mode: ['advanced', 'extreme'].includes(settings.adblockMode) ? 'advanced' : 'on' };
  }
  function registrable(host) {
    if (domainCache.has(host)) return domainCache.get(host);
    const value = siteDomain(host);
    if (domainCache.size >= 2048) domainCache.clear();
    domainCache.set(host, value);
    return value;
  }
  function context(url, top, type, isPopup) {
    const host = hostname(url.hostname), topHost = top ? hostname(top.hostname) : '';
    const resources = RESOURCE_MAP[String(type).toLowerCase()] || ['other'];
    return { url: url.href, lowerURL: url.href.toLowerCase(), host, topHost,
      resources: isPopup ? [...resources, 'popup'] : resources,
      party: top ? (registrable(host) === registrable(topHost) ? 'first-party' : 'third-party') : null };
  }
  function matches(rule, ctx) {
    if ((rule.ifDomains || rule.unlessDomains || rule.loads) && !ctx.topHost) return false;
    if (rule.ifDomains && !rule.ifDomains.some(domain => domainMatches(ctx.topHost, domain))) return false;
    if (rule.unlessDomains?.some(domain => domainMatches(ctx.topHost, domain))) return false;
    if (rule.loads && !rule.loads.includes(ctx.party)) return false;
    if (rule.resources && !rule.resources.some(type => ctx.resources.includes(type))) return false;
    if (rule.literal && !ctx.lowerURL.includes(rule.literal)) return false;
    stats.lastRegexTests++;
    if (!rule.regex) rule.regex = new RegExp(rule.source, rule.sensitive ? '' : 'i');
    return rule.regex.test(ctx.url);
  }
  function evaluate(ctx) {
    let block = -1, ignore = -1;
    stats.lastCandidates = 0; stats.lastRegexTests = 0;
    const examine = rule => {
      stats.lastCandidates++;
      if (matches(rule, ctx)) {
        if (rule.action === 'block') block = Math.max(block, rule.id);
        else ignore = Math.max(ignore, rule.id);
      }
    };
    for (const rule of fallback) examine(rule);
    for (const key of trigrams(ctx.lowerURL)) {
      const bucket = index.get(key);
      if (bucket) for (const rule of bucket) examine(rule);
    }
    return { block, ignore };
  }

  return {
    stats,
    get error() { return error; },
    shouldBlock(details = {}) {
      try {
        const url = parseURL(details.url);
        if (!url) return false;
        // During main-frame navigation the resolver may still hold the old URL.
        // Popup preflight uses the opener's top URL for domain/party rules.
        const top = String(details.resourceType).toLowerCase() === 'mainframe' && !details.isPopup ? url : parseURL(getTopURL(details));
        if (!settingsFor(top)) return false;
        const result = evaluate(context(url, top, details.resourceType, details.isPopup));
        return result.block > result.ignore;
      } catch { return false; }
    },
    cosmeticCSS(value) {
      try {
        const url = parseURL(value), settings = url && settingsFor(url);
        if (!settings) return '';
        const key = `${settings.mode}|${url.href}`;
        if (cssCache.has(key)) return cssCache.get(key);
        const ctx = context(url, url, 'mainFrame', false);
        const { ignore } = evaluate(ctx);
        const selectors = new Set();
        for (const rule of cosmetics) if (rule.id > ignore && matches(rule, ctx)) selectors.add(rule.selector);
        if (settings.mode === 'advanced') selectors.add(ADVANCED_SELECTORS);
        // Separate rules keep a single invalid CSS selector from disabling all
        // other selectors. Braces/comments are rejected during compilation.
        const css = [...selectors].map(selector => `${selector}{display:none!important;}`).join('\n');
        if (cssCache.size >= 32) cssCache.clear();
        cssCache.set(key, css);
        return css;
      } catch { return ''; }
    },
  };
}

module.exports = { createBlocker };
