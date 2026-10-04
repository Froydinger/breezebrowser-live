'use strict';

// Only this isolated renderer calls the allow-listed preload bridge. Website
// content never receives this object, and no remote text is interpreted as HTML.
(() => {
  const $ = (id) => document.getElementById(id);
  const bridge = window.breeze;
  const INTERNAL_PAGES = new Set(['newtab', 'settings', 'history', 'bookmarks', 'downloads', 'passwords', 'onboarding', 'updates']);
  const ICONS = {
    workspace: ['M3 5h13v10H3z', 'M7 3h12v9', 'M15 20h7l-1-3-2-1-2 1z', 'M19 12a2 2 0 1 0 0 4a2 2 0 1 0 0-4'],
    sidebar: ['M3 4h18v16H3z', 'M8 4v16', 'M5.5 7v2'], back: ['m14 5-7 7 7 7'], forward: ['m10 5 7 7-7 7'],
    reload: ['M19 7a8 8 0 1 0 1 8', 'M19 3v5h-5'], link: ['m10 14 4-4', 'M8 16 6 18a4 4 0 0 1-5-5l5-5a4 4 0 0 1 5 0', 'm16 8 2-2a4 4 0 0 1 5 5l-5 5a4 4 0 0 1-5 0'],
    pin: ['m15 3 6 6-4 1-3 5-5-5 5-3z', 'm10 14-7 7'], bookmark: ['M6 3h12v18l-6-4-6 4z'], split: ['M3 4h18v16H3z', 'M12 4v16'], more: ['M5 12h.01M12 12h.01M19 12h.01'],
    minimize: ['M5 12h14'], maximize: ['M5 5h14v14H5z'], close: ['m6 6 12 12', 'm18 6-12 12'], plus: ['M12 5v14', 'M5 12h14'],
    globe: ['M21 12a9 9 0 1 0-18 0a9 9 0 1 0 18 0', 'M3 12h18', 'M12 3c-5 5-5 13 0 18', 'M12 3c5 5 5 13 0 18', 'M5 7h14', 'M5 17h14'],
    settings: ['m10 3-.6 3-2 .9-2.7-1.2-2 3.5L5 11v2l-2.3 1.8 2 3.5L7.4 17l2 .9.6 3h4l.6-3 2-.9 2.7 1.2 2-3.5L19 13v-2l2.3-1.8-2-3.5L16.6 7l-2-.9L14 3z', 'M15 12a3 3 0 1 0-6 0a3 3 0 1 0 6 0'],
    moon: ['M20 15A8 8 0 0 1 9 4 8.5 8.5 0 1 0 20 15'], sun: ['M16 12a4 4 0 1 0-8 0a4 4 0 1 0 8 0', 'M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5 19 19M19 5l-1.5 1.5M6.5 17.5 5 19'],
    system: ['M7 8a5 5 0 0 1 10 0v8a5 5 0 0 1-10 0z', 'M7 9h10', 'M12 3v6'], history: ['M21 12a9 9 0 1 0-18 0a9 9 0 1 0 18 0', 'M12 6v7H7'],
    download: ['M12 3v13', 'm6 11 6 6 6-6', 'M4 18v3h16v-3'], search: ['M17 10a7 7 0 1 0-14 0a7 7 0 1 0 14 0', 'm15 15 6 6'],
    document: ['M6 3h8l5 5v13H6z', 'M14 3v6h5', 'M9 13h7M9 17h7'], bell: ['M7 8a5 5 0 0 1 10 0c0 7 3 7 3 9H4c0-2 3-2 3-9', 'M10 21h4'],
    camera: ['M3 7h4l2-3h6l2 3h4v13H3z', 'M16 13a4 4 0 1 0-8 0a4 4 0 1 0 8 0'], send: ['m3 10 18-7-7 18-3-8z', 'm11 13 10-10'], attach: ['m8 14 7-7a3 3 0 0 1 4 4l-9 9a5 5 0 0 1-7-7L13 3', 'm7 10 6-6'],
    up: ['m5 15 7-7 7 7'], down: ['m5 9 7 7 7-7'], expand: ['M9 3H3v6M15 21h6v-6', 'm3 3 7 7M21 21l-7-7'], compose: ['M10 4H4v16h16v-7', 'm13 5 4-4 4 4-12 12-5 1 1-5z'],
    shield: ['m12 3 8 3v6c0 5-8 9-8 9S4 17 4 12V6z', 'm8 12 3 3 5-6'], key: ['M11 8a4 4 0 1 0-8 0a4 4 0 1 0 8 0', 'm10 11 11 10M15 16l3-3M18 19l3-3'],
    cloud: ['M6 18a5 5 0 0 1-1-10 7 7 0 0 1 13 1 4.5 4.5 0 0 1 0 9z'], check: ['m5 12 4 4L19 6'], trash: ['M3 6h18M9 3h6', 'm5 6 1 15h12l1-15M10 10v7M14 10v7'],
    folder: ['M3 6h7l2 3h9v11H3z'], copy: ['M8 8h12v13H8z', 'M16 8V3H3v13h5'], mute: ['m11 4-5 5H3v6h3l5 5z', 'm16 9 6 6m0-6-6 6'], volume: ['m11 4-5 5H3v6h3l5 5z', 'M15 8c3 2 3 6 0 8M18 5c5 4 5 10 0 14'],
    play: ['m9 5 11 7-11 7z'], stop: ['M6 6h12v12H6z'], eye: ['M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z', 'M15 12a3 3 0 1 0-6 0a3 3 0 1 0 6 0'],
    mail: ['M3 5h18v14H3z', 'm3 6 9 7 9-7'], logout: ['M10 4H4v16h6', 'M8 12h13m-5-5 5 5-5 5'], help: ['M21 12a9 9 0 1 0-18 0a9 9 0 1 0 18 0', 'M9 8a3 3 0 0 1 6 0c0 2-3 2-3 5M12 17h.01']
  };
  const tasks = [
    { slug: 'research', title: 'Research', description: 'Read sources and build a sourced summary', icon: 'search' },
    { slug: 'summarize', title: 'Summarize', description: 'Get the key points from the current page', icon: 'document' },
    { slug: 'factcheck', title: 'Fact-check', description: 'Check a claim against reliable sources', icon: 'shield' },
    { slug: 'youtube', title: 'Creator Tools', description: 'Analyze the YouTube page you’re viewing', icon: 'play' }
  ];
  let state = { version: '', tabs: [], pins: [], groups: [], settings: {}, bookmarks: [], history: [], downloads: [], passwords: [], chats: [], reminders: [], cloud: {}, assistant: {}, internalPage: 'newtab' };
    let pageKey = '';
  let pageFingerprint = '';
  let settingsSection = 'general';
  let historySection = 'browsing';
  let query = '';
  let toastTimeout;
  let clockTimeout;
  let layoutFrame;
  let lastLayout = '';
  let splitRatio = 0.5;
  let menuAnchor;
  let dialogSubmit;
  let dialogReturnFocus;
  let localAssistantFullscreen = false;
  let assistantFingerprint = '';
  let cloudAuthBusy = false;
  const mentionedTabs = new Set();
  const systemTheme = window.matchMedia('(prefers-color-scheme: dark)');

  function node(tag, className, text) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = String(text);
    return element;
  }
  function icon(name) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('aria-hidden', 'true');
    for (const d of ICONS[name] || ICONS.globe) {
      const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      path.setAttribute('d', d); svg.append(path);
    }
    return svg;
  }
  function hydrateIcons(root = document) { root.querySelectorAll('[data-icon]').forEach((target) => target.replaceChildren(icon(target.dataset.icon))); }
  function button(text, className, fn, iconName) {
    const element = node('button', className);
    element.type = 'button';
    if (iconName) element.append(icon(iconName));
    if (text) element.append(node('span', '', text));
    if (fn) element.addEventListener('click', fn);
    return element;
  }
  function iconButton(label, name, fn) {
    const element = button('', 'icon-button', fn, name);
    element.title = label; element.setAttribute('aria-label', label); return element;
  }
  function activeTab() { return state.tabs.find((tab) => tab.id === state.activeTabId); }
  function isInternalURL(url = '') { return !url || /^(?:breeze:|about:blank)/i.test(url); }
  function currentPage() {
    if (state.internalPage === null) return '';
    if (INTERNAL_PAGES.has(state.internalPage)) return state.internalPage;
    const tab = activeTab();
    if (!tab || !tab.url || tab.url === 'about:blank') return 'newtab';
    const page = tab.url.match(/^breeze:\/\/([a-z]+)/i)?.[1];
    return INTERNAL_PAGES.has(page) ? page : '';
  }
  function hostName(url = '') { try { const parsed = new URL(url); return /^https?:$/.test(parsed.protocol) ? parsed.hostname.replace(/^www\./, '') : ''; } catch { return ''; } }
  function dateText(value, full = false) {
    const number = typeof value === 'number' && value < 1e11 ? value * 1000 : value;
    const date = new Date(number || 0);
    if (!value || Number.isNaN(date.getTime())) return '';
    return new Intl.DateTimeFormat(undefined, full ? { dateStyle: 'medium', timeStyle: 'short' } : { dateStyle: 'medium' }).format(date);
  }
  function siteMark(item = {}, sizeClass = '') {
    const mark = node('span', `site-mark ${sizeClass}`.trim());
    const favicon = item.favicon || item.faviconURL;
    if (typeof favicon === 'string' && /^(data:image\/(?:png|jpeg|webp|gif|x-icon|vnd.microsoft.icon);|https:\/\/)/i.test(favicon)) {
      const image = node('img'); image.alt = ''; image.src = favicon; image.referrerPolicy = 'no-referrer';
      image.addEventListener('error', () => { mark.replaceChildren(icon('globe')); }, { once: true }); mark.append(image); return mark;
    }
    const host = hostName(item.url);
    if (/(^|\.)youtube\.com$/.test(host)) { mark.classList.add('youtube'); mark.textContent = '▶'; }
    else if (/(^|\.)google\.com$/.test(host) && !host.startsWith('mail.')) { mark.classList.add('google'); mark.textContent = 'G'; }
    else if (host === 'x.com' || host === 'twitter.com') { mark.classList.add('x'); mark.textContent = '𝕏'; }
    else if (host.startsWith('mail.')) { mark.classList.add('mail'); mark.append(icon('mail')); }
    else if (host) { mark.textContent = (item.title || host)[0].toUpperCase(); }
    else mark.append(icon('globe'));
    return mark;
  }
  async function invoke(action, payload = {}) {
    if (!bridge?.invoke) { showToast('Open this page in the Breeze app to use browser controls.'); return null; }
    try {
      const result = await bridge.invoke(action, payload);
      if (result?.ok === false || (result?.error && !result?.state)) throw new Error(typeof result.error === 'string' ? result.error : result.error.message || 'The action could not be completed.');
      if (result?.state?.tabs) receiveState(result.state);
      return result;
    } catch (error) {
      showToast(error?.message || 'The action could not be completed.');
      throw error;
    }
  }
  function run(action, payload) { return invoke(action, payload).catch(() => null); }
  function showToast(message) {
    $('toast').textContent = String(message); $('toast').hidden = false;
    clearTimeout(toastTimeout); toastTimeout = setTimeout(() => { $('toast').hidden = true; }, 5500);
  }
  async function openPage(page) {
    if (!INTERNAL_PAGES.has(page)) return;
    closeMenu(); closePalette();
    query = '';
    await run('browser:internal', { page });
  }
  function navigate(url, newTab = false) {
    const input = String(url || '').trim();
    if (!input) return;
    if (input.startsWith('/')) return sendAssistant(input);
    const internal = input.match(/^breeze:\/\/([a-z]+)/i)?.[1];
    if (INTERNAL_PAGES.has(internal)) return openPage(internal);
    closeMenu(); closePalette();
    return run(newTab ? 'tab:new' : 'tab:navigate', newTab ? { url: input } : { id: state.activeTabId, url: input });
  }
  function looksLikeURL(value) { return /^(?:https?:\/\/|localhost(?::\d+)?(?:\/|$)|(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:[/?#]|$))/i.test(value.trim()); }
  function updateTheme() {
    const mode = state.settings.theme || 'dark';
    document.documentElement.dataset.theme = mode === 'system' ? ((state.systemDark ?? systemTheme.matches) ? 'dark' : 'light') : mode;
    const names = { light: 'sun', dark: 'moon', system: 'system' };
    $('theme-toggle').replaceChildren(icon(names[mode] || 'moon'));
    $('theme-toggle').title = `Theme: ${mode}. Click to change.`;
  }
  function cycleTheme() {
    const current = state.settings.theme || 'dark';
    run('settings:update', { theme: current === 'light' ? 'dark' : current === 'dark' ? 'system' : 'light' });
  }
  function updateClock() {
    clearTimeout(clockTimeout);
    if (document.hidden) return;
    const now = new Date();
    const time = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit', hour12: !state.settings.clock24 }).format(now);
    const date = new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric' }).format(now);
    $('clock').textContent = `${time}  ·  ${date}`;
    clockTimeout = setTimeout(updateClock, 60000 - (Date.now() % 60000));
  }
  function receiveState(next) {
    if (!next || typeof next !== 'object') return;
    state = { ...state, ...next, settings: { ...state.settings, ...next.settings }, assistant: { ...state.assistant, ...next.assistant }, cloud: { ...state.cloud, ...next.cloud } };
    for (const key of ['tabs', 'pins', 'groups', 'bookmarks', 'history', 'downloads', 'passwords', 'chats', 'reminders']) if (!Array.isArray(state[key])) state[key] = [];
    render();
  }
  function render() {
    updateTheme(); updateClock(); renderBuildNotice(); renderToolbar(); renderSidebar(); renderPage(); renderAssistant(); renderRestorePrompt(); scheduleLayout();
  }
  function aeroUnavailable() { return state.cloud.aeroConfigured === false || (state.development && !state.cloud.aeroConfigured); }
  function aeroUnavailableReason() { return state.development ? 'Aero isn’t configured in this Windows test build.' : 'Aero isn’t configured in this build.'; }
  function renderBuildNotice() {
    const development = Boolean(state.development);
    $('app').classList.toggle('test-build', development); $('build-notice').hidden = !development;
    if (!development) { $('build-notice').textContent = ''; return; }
    const unavailable = [];
    if (!state.cloud.aeroConfigured) unavailable.push('Aero');
    if (!state.cloud.configured) unavailable.push('Cloud');
    const message = unavailable.length ? `${unavailable.join(' and ')} ${unavailable.length > 1 ? 'aren’t' : 'isn’t'} configured` : 'For testing only';
    $('build-notice').textContent = `${state.buildLabel || 'Windows test build'} • ${message}`;
  }
  function renderToolbar() {
    const tab = activeTab(); const internal = currentPage();
    $('go-back').disabled = !tab?.canGoBack;
    $('go-forward').disabled = !tab?.canGoForward;
    $('reload').disabled = !tab || Boolean(internal);
    $('reload').replaceChildren(icon(tab?.loading ? 'stop' : 'reload'));
    $('reload').title = tab?.loading ? 'Stop loading' : 'Reload (Ctrl+R)';
    if (document.activeElement !== $('address')) $('address').value = internal === 'newtab' ? '' : internal ? `breeze://${internal}` : tab?.url || '';
    const valid = tab && !isInternalURL(tab.url);
    $('bookmark-current').disabled = !valid;
    $('pin-current').disabled = !valid;
    $('page-info').disabled = !valid;
    $('bookmark-current').classList.toggle('active', Boolean(valid && state.bookmarks.some((item) => item.url === tab.url)));
    $('pin-current').classList.toggle('active', Boolean(valid && state.pins.some((item) => item.url === tab.url)));
    $('split-button').classList.toggle('active', Boolean(state.splitTabId));
    const addressHost = state.settings.urlBarPosition === 'sidebar' ? $('sidebar-address-host') : $('toolbar');
    if ($('address-form').parentElement !== addressHost) {
      if (addressHost === $('toolbar')) addressHost.insertBefore($('address-form'), addressHost.querySelector('.page-actions'));
      else addressHost.append($('address-form'));
    }
    const appName = state.development ? 'Breeze Test' : 'Breeze';
    document.title = tab?.title && tab.title !== 'New Tab' ? `${tab.title} — ${appName}` : appName;
  }
  function renderSidebar() {
    const pins = $('pins'); pins.replaceChildren(); pins.dataset.size = ['small', 'medium', 'large'].includes(state.settings.pinSize) ? state.settings.pinSize : 'large';
    state.pins.forEach((pin) => {
      const item = button('', 'pin', () => {
        const existing = state.tabs.find((tab) => tab.url === pin.url);
        if (existing) run('tab:activate', { id: existing.id }); else run('tab:new', { url: pin.url, pinned: true });
      });
      item.title = pin.title || hostName(pin.url) || pin.url; item.setAttribute('aria-label', item.title);
      item.classList.toggle('active', activeTab()?.url === pin.url); item.append(siteMark(pin));
      item.addEventListener('contextmenu', (event) => { event.preventDefault(); openMenu([
        { label: 'Open in a new tab', icon: 'plus', fn: () => navigate(pin.url, true) },
        { label: 'Open in split view', icon: 'split', fn: () => run('tab:new', { url: pin.url, split: true }) },
        { label: 'Unpin site', icon: 'pin', fn: () => run('pin:remove', { id: pin.id, url: pin.url }) }
      ], item, event); });
      pins.append(item);
    });
    const tabs = $('tabs'); tabs.replaceChildren();
    const ungrouped = state.tabs.filter((tab) => (!tab.groupId || !state.groups.some((group) => group.id === tab.groupId)) && !(tab.pinned && state.pins.some((pin) => pin.url === tab.url)));
    for (const group of state.groups) {
      const groupTabs = state.tabs.filter((tab) => tab.groupId === group.id);
      const heading = button('', 'group-heading', () => run('group:update', { id: group.id, collapsed: !group.collapsed }));
      heading.setAttribute('aria-expanded', String(!group.collapsed)); heading.append(icon(group.collapsed ? 'forward' : 'down'));
      const dot = node('span', 'group-dot');
      if (/^#[\da-f]{6}$/i.test(group.color || '')) dot.style.backgroundColor = group.color;
      heading.append(dot, node('span', '', group.title || 'Tab group'), node('span', 'count', groupTabs.length));
      heading.addEventListener('contextmenu', (event) => { event.preventDefault(); openMenu([
        { label: 'Rename group', icon: 'compose', fn: () => editGroup(group) },
        { label: group.collapsed ? 'Expand group' : 'Collapse group', icon: 'folder', fn: () => run('group:update', { id: group.id, collapsed: !group.collapsed }) },
        { label: 'Remove group', icon: 'trash', fn: () => run('group:update', { id: group.id, remove: true }) }
      ], heading, event); });
      heading.addEventListener('dragover', (event) => event.preventDefault());
      heading.addEventListener('drop', (event) => { event.preventDefault(); const id = event.dataTransfer.getData('text/breeze-tab'); if (state.tabs.some((tab) => tab.id === id)) run('group:assign', { tabId: id, groupId: group.id }); });
      tabs.append(heading);
      if (!group.collapsed) { const list = node('div', 'group-tabs'); groupTabs.forEach((tab) => list.append(tabRow(tab))); tabs.append(list); }
    }
    ungrouped.forEach((tab) => tabs.append(tabRow(tab)));
    const reminders = $('sidebar-reminders'); reminders.replaceChildren();
    const upcoming = state.reminders.filter((item) => !item.completed && !item.fired).sort((a, b) => new Date(a.dueAt || a.fireAt) - new Date(b.dueAt || b.fireAt))[0];
    if (upcoming) {
      const reminder = button('', 'sidebar-reminder', () => { settingsSection = 'reminders'; openPage('settings'); });
      reminder.append(icon('bell'), node('span', '', upcoming.text || upcoming.title)); reminder.title = dateText(upcoming.dueAt || upcoming.fireAt, true); reminders.append(reminder);
    }
  }
  function tabRow(tab) {
    const row = node('div', 'tab-row'); row.tabIndex = 0; row.draggable = true;
    row.setAttribute('role', 'tab'); row.setAttribute('aria-selected', String(tab.id === state.activeTabId)); row.setAttribute('aria-label', tab.title || 'New Tab');
    row.classList.toggle('active', tab.id === state.activeTabId); row.classList.toggle('sleeping', Boolean(tab.sleeping));
    row.append(siteMark(tab), node('span', 'tab-label', tab.title || 'New Tab'));
    if (tab.loading) row.append(node('span', 'tab-badge', '•••'));
    else if (tab.sleeping) row.append(node('span', 'tab-badge', 'z'));
    if (tab.muted) row.append(iconButton('Unmute tab', 'mute', (event) => { event.stopPropagation(); run('tab:mute', { id: tab.id, muted: false }); }));
    if (tab.id === state.splitTabId) row.append(icon('split'));
    row.append(iconButton('Close tab', 'close', (event) => { event.stopPropagation(); run('tab:close', { id: tab.id }); }));
    row.addEventListener('click', () => run('tab:activate', { id: tab.id }));
    row.addEventListener('auxclick', (event) => { if (event.button === 1) { event.preventDefault(); run('tab:close', { id: tab.id }); } });
    row.addEventListener('keydown', (event) => { if (event.target !== row) return; if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); run('tab:activate', { id: tab.id }); } if (event.key === 'Delete') run('tab:close', { id: tab.id }); });
    row.addEventListener('dragstart', (event) => { event.dataTransfer.setData('text/breeze-tab', tab.id); event.dataTransfer.effectAllowed = 'move'; });
    row.addEventListener('contextmenu', (event) => { event.preventDefault(); openMenu(tabMenu(tab), row, event); });
    return row;
  }
  function tabMenu(tab) {
    return [
      { label: 'Duplicate tab', icon: 'copy', fn: () => run('tab:duplicate', { id: tab.id }) },
      { label: 'Open in split view', icon: 'split', fn: () => run('tab:activate', { id: tab.id, split: true }) },
      { label: state.pins.some((pin) => pin.url === tab.url) ? 'Unpin site' : 'Pin site', icon: 'pin', disabled: isInternalURL(tab.url), fn: () => togglePin(tab) },
      { label: tab.muted ? 'Unmute tab' : 'Mute tab', icon: tab.muted ? 'volume' : 'mute', fn: () => run('tab:mute', { id: tab.id, muted: !tab.muted }) },
      { label: tab.sleeping ? 'Wake tab' : 'Put tab to sleep', icon: 'moon', disabled: isInternalURL(tab.url) || (tab.id === state.activeTabId && !tab.sleeping) || tab.id === state.splitTabId, fn: () => run('tab:sleep', { id: tab.id, sleeping: !tab.sleeping }) },
      null,
      { label: 'Move to group…', icon: 'folder', fn: () => assignGroup(tab) },
      { label: 'Close tab', icon: 'close', shortcut: 'Ctrl+W', fn: () => run('tab:close', { id: tab.id }) }
    ];
  }
  function toggleBookmark(tab = activeTab()) {
    if (!tab || isInternalURL(tab.url)) return;
    const existing = state.bookmarks.find((item) => item.url === tab.url);
    run(existing ? 'bookmark:remove' : 'bookmark:add', existing ? { id: existing.id, url: existing.url } : { url: tab.url, title: tab.title });
  }
  function togglePin(tab = activeTab()) {
    if (!tab || isInternalURL(tab.url)) return;
    const existing = state.pins.find((item) => item.url === tab.url);
    run(existing ? 'pin:remove' : 'pin:add', existing ? { id: existing.id, url: existing.url } : { url: tab.url, title: tab.title });
  }
  function renderRestorePrompt() {
    let banner = $('restore-banner');
    const rows = Array.isArray(state.restoreTabs) ? state.restoreTabs : [];
    const show = rows.length && state.settings.restoreTabs === 'ask' && currentPage() !== 'onboarding';
    if (!show) { banner?.remove(); return; }
    if (!banner) { banner = node('div', 'restore-banner'); banner.id = 'restore-banner'; $('sidebar-reminders').before(banner); }
    banner.replaceChildren(node('strong', '', 'Pick up where you left off?'), node('span', '', `${rows.length} tabs from your last session`));
    const actions = node('div', 'button-row');
    actions.append(button('Restore tabs', 'secondary-button', () => run('browser:restore', { restore: true })), button('Dismiss', 'quiet-button', () => run('browser:restore', { restore: false })));
    banner.append(actions);
  }
  function pageSignature(page) {
    switch (page) {
      case 'newtab': return JSON.stringify([state.development, state.cloud.aeroConfigured, state.settings.showGreeting, state.settings.newTabSuggestions, state.history.map((item) => [item.url, item.title])]);
      case 'settings': return JSON.stringify([settingsSection, state.settings, state.cloud, state.reminders, state.version]);
      case 'history': return JSON.stringify([historySection, state.history, state.chats]);
      case 'bookmarks': return JSON.stringify(state.bookmarks);
      case 'downloads': return JSON.stringify(state.downloads);
      case 'passwords': return JSON.stringify(state.passwords);
      default: return state.version;
    }
  }
  function renderPage(force = false) {
    const page = currentPage();
    $('browser-region').hidden = Boolean(page);
    $('page-content').hidden = !page;
    $('split-toolbar').hidden = Boolean(page) || !state.splitTabId;
    $('browser-secondary').hidden = !state.splitTabId;
    $('split-divider').hidden = !state.splitTabId;
    const splitTab = state.tabs.find((tab) => tab.id === state.splitTabId);
    $('split-title').textContent = splitTab ? `Split view · ${splitTab.title || hostName(splitTab.url)}` : '';
    if (!page) { if (pageKey) { $('page-content').replaceChildren(); pageKey = ''; pageFingerprint = ''; } return; }
    const fingerprint = pageSignature(page);
    if (!force && page === pageKey && fingerprint === pageFingerprint) return;
    const oldScroll = $('page-content').scrollTop;
    const focus = document.activeElement;
    const preserveFocus = focus && $('page-content').contains(focus) && focus.id;
    const value = preserveFocus && 'value' in focus ? focus.value : undefined;
    const selectionStart = preserveFocus ? focus.selectionStart : null;
    const selectionEnd = preserveFocus ? focus.selectionEnd : null;
    const samePage = pageKey === page;
    const drafts = samePage ? [...$('page-content').querySelectorAll('input[id]:not([type=checkbox]),textarea[id]')].filter((field) => !field.id.startsWith('setting-')).map((field) => [field.id, field.value]) : [];
    pageKey = page; pageFingerprint = fingerprint;
    const pages = { newtab: newTabPage, settings: settingsPage, history: historyPage, bookmarks: bookmarksPage, downloads: downloadsPage, passwords: passwordsPage, onboarding: onboardingPage, updates: updatesPage };
    $('page-content').replaceChildren(pages[page]());
    for (const [id, draft] of drafts) if ($(id)) $(id).value = draft;
    if (samePage) $('page-content').scrollTop = oldScroll;
    else $('page-content').scrollTop = 0;
    if (preserveFocus && $(focus.id)) {
      const replacement = $(focus.id);
      if (value !== undefined && replacement.type !== 'checkbox' && replacement.tagName !== 'SELECT') replacement.value = value;
      replacement.focus({ preventScroll: true });
      if (selectionStart != null && typeof replacement.setSelectionRange === 'function') { try { replacement.setSelectionRange(selectionStart, selectionEnd); } catch { /* select/date inputs have no text selection */ } }
    }
    scheduleLayout();
  }
  function newTabPage() {
    const page = node('section', 'newtab'); const column = node('div', 'newtab-column');
    const logo = node('img', 'hero-logo'); logo.src = 'assets/icon.png'; logo.alt = 'Breeze';
    column.append(logo);
    if (state.settings.showGreeting !== false) column.append(node('h1', '', 'What are we exploring?'));
    const form = node('form', 'ask-bar'); const unavailable = aeroUnavailable();
    const input = node('textarea'); input.id = 'newtab-input'; input.rows = 1; input.placeholder = unavailable ? 'Search or enter a URL' : 'Ask Aero, or enter a URL'; input.setAttribute('aria-label', input.placeholder);
    const attach = iconButton('Attach an image to Aero', 'camera', () => { openAssistant(); run('assistant:attach'); }); attach.disabled = unavailable; if (unavailable) attach.title = aeroUnavailableReason(); form.append(attach, input);
    const send = button('', 'send-button', null, 'send'); send.type = 'submit'; send.title = unavailable ? 'Search or open address' : 'Ask Aero'; send.setAttribute('aria-label', send.title); form.append(send);
    const submit = async (search = false) => { const text = input.value.trim(); if (!text) return; closePalette(); input.value = ''; autoGrow(input); const result = await (search || unavailable || looksLikeURL(text) ? navigate(text) : sendAssistant(text)); if (result === null && input.isConnected && !input.value) { input.value = text; autoGrow(input); } };
    form.addEventListener('submit', (event) => { event.preventDefault(); submit(); });
    input.addEventListener('keydown', (event) => { if (event.key === 'Enter' && !event.ctrlKey && !event.altKey) { event.preventDefault(); submit(event.shiftKey); } });
    input.addEventListener('input', () => { autoGrow(input); updatePalette(input); });
    const help = node('div', 'help-row'); const helpText = node('span', 'key-help', unavailable ? 'Enter to search or open an address' : 'Enter to ask Aero · Shift+Enter to search'); helpText.hidden = true;
    const helpButton = button('?', 'help-button', () => { helpText.hidden = !helpText.hidden; }); helpButton.title = 'New-tab keyboard shortcuts'; helpButton.setAttribute('aria-label', 'Show keyboard shortcuts'); help.append(helpText, helpButton);
    const actions = node('div', 'quick-actions');
    [['Research something', 'search', '/research '], ['Check a fact', 'document', '/factcheck '], ['Set a reminder', 'bell', 'reminder']].forEach(([title, name, command]) => {
      const action = button('', 'task-card', () => { if (command === 'reminder') reminderDialog(); else { input.value = command; input.focus(); updatePalette(input); } });
      action.disabled = unavailable && command !== 'reminder'; if (action.disabled) action.title = aeroUnavailableReason(); action.append(node('span', '', title), icon(name)); actions.append(action);
    });
    column.append(form, help, actions);
    const topSites = getTopSites();
    if (topSites.length) {
      const favorites = node('section', 'favorites');
      if (state.settings.newTabSuggestions === false) favorites.append(button('Show suggested sites', 'quiet-button', () => run('settings:update', { newTabSuggestions: true })));
      else {
        favorites.append(node('h2', '', 'Your favorites'));
        const list = node('div', 'favorite-list');
        topSites.forEach((site) => { const favorite = button('', 'favorite', () => navigate(site.url)); favorite.title = site.title || site.url; favorite.append(siteMark(site), node('span', '', site.title || hostName(site.url))); list.append(favorite); });
        list.append(iconButton('Hide suggested sites', 'close', () => run('settings:update', { newTabSuggestions: false })));
        favorites.append(list);
      }
      column.append(favorites);
    }
    page.append(column); return page;
  }
  function getTopSites() {
    const sites = new Map();
    state.history.forEach((item) => { const host = hostName(item.url); if (!host) return; const existing = sites.get(host); if (existing) existing.count += 1; else sites.set(host, { ...item, count: 1 }); });
    return [...sites.values()].sort((a, b) => b.count - a.count).slice(0, 6);
  }
  function pageBase(title, description, action) {
    const page = node('section', 'internal-page'); const header = node('header', 'page-heading');
    const logo = node('img'); logo.src = 'assets/nav-icon.png'; logo.alt = '';
    const copy = node('div'); copy.append(node('h1', '', title)); if (description) copy.append(node('p', '', description));
    header.append(logo, copy, node('span', 'spacer')); if (action) header.append(action);
    page.append(header); return page;
  }
  function emptyState(iconName, title, description) {
    const empty = node('div', 'empty-state'); empty.append(icon(iconName), node('h2', '', title), node('p', '', description)); return empty;
  }
  function card(...children) { const element = node('div', 'card'); element.append(...children); return element; }
  function settingRow(label, hint, control) {
    const row = node('div', 'setting-row'); const copy = node('div', 'setting-copy'); copy.append(node('span', 'setting-label', label));
    if (hint) copy.append(node('span', 'setting-hint', hint)); if (control.matches('input,select,textarea')) control.setAttribute('aria-label', label); else control.querySelector('input')?.setAttribute('aria-label', label); row.append(copy, control); return row;
  }
  function selectSetting(key, options) {
    const select = node('select'); select.id = `setting-${key}`; select.setAttribute('aria-label', key);
    options.forEach(([value, label]) => { const option = node('option', '', label); option.value = value; select.append(option); });
    select.value = String(state.settings[key] ?? options[0][0]);
    select.addEventListener('change', () => run('settings:update', { [key]: select.value })); return select;
  }
  function toggleSetting(key, fallback = false, onChange) {
    const label = node('label', 'toggle'); const input = node('input'); input.type = 'checkbox'; input.id = `setting-${key}`; input.checked = Boolean(state.settings[key] ?? fallback); input.setAttribute('aria-label', key);
    input.addEventListener('change', () => onChange ? onChange(input.checked) : run('settings:update', { [key]: input.checked })); label.append(input, node('span')); return label;
  }
  function numberSetting(key, fallback, min, max) {
    const input = node('input'); input.type = 'number'; input.id = `setting-${key}`; input.min = min; input.max = max; input.step = 1; input.value = state.settings[key] ?? fallback;
    input.addEventListener('change', () => { if (input.reportValidity()) run('settings:update', { [key]: Number(input.value) }); }); return input;
  }
  function textField(label, id, type = 'text', value = '') {
    const wrapper = node('label', 'form-label', label); const input = node('input'); input.type = type; input.id = id; input.value = value; wrapper.append(input); return { wrapper, input };
  }
  function settingsPage() {
    const page = pageBase('Settings', 'Make Breeze feel like yours.');
    const layout = node('div', 'settings-layout'); const rail = node('nav', 'settings-rail'); rail.setAttribute('aria-label', 'Settings sections');
    const sections = [['general', 'General'], ['search', 'Search'], ['tabs', 'Tabs & sidebar'], ['appearance', 'Appearance'], ['cloud', 'Breeze Cloud'], ['aero', 'Aero'], ['privacy', 'Privacy & security'], ['reminders', 'Reminders'], ['about', 'About Breeze']];
    sections.forEach(([key, title]) => { const entry = button(title, settingsSection === key ? 'active' : '', () => { settingsSection = key; renderPage(true); }); entry.setAttribute('aria-current', settingsSection === key ? 'page' : 'false'); rail.append(entry); });
    const section = node('section', 'settings-section');
    const heading = sections.find(([key]) => key === settingsSection)?.[1] || 'General'; section.append(node('h2', '', heading));
    if (settingsSection === 'general') {
      section.append(node('p', 'section-intro', 'A quieter place to browse, built around you.'), card(
        settingRow('On startup', 'Choose whether your previous tabs open with Breeze.', selectSetting('restoreTabs', [['ask', 'Ask to restore tabs'], ['always', 'Restore tabs'], ['never', 'New tab']])),
        settingRow('Suggested sites', 'Show your most-visited sites on the new tab page. Uses local browsing history.', toggleSetting('newTabSuggestions', true)),
        settingRow('New-tab greeting', 'Show “What are we exploring?” above the ask bar.', toggleSetting('showGreeting', true)),
        settingRow('24-hour clock', 'Use a 24-hour clock in the sidebar.', toggleSetting('clock24'))
      ));
    } else if (settingsSection === 'search') {
      section.append(node('p', 'section-intro', 'Type an address or search in the address bar. On a new tab, Enter asks Aero and Shift+Enter searches the web.'), card(
        settingRow('Search engine', 'Used for address-bar searches and Aero’s web search.', selectSetting('searchEngine', [['google', 'Google'], ['bing', 'Bing'], ['duckduckgo', 'DuckDuckGo'], ['brave', 'Brave'], ['spectra', 'Spectra']]))
      ));
    } else if (settingsSection === 'tabs') {
      section.append(node('p', 'section-intro', 'Keep what matters close. Right-click any tab for groups, pinning, mute, and sleep.'), card(
        settingRow('Address bar', 'Place the address field at the top or in the sidebar.', selectSetting('urlBarPosition', [['top', 'Top'], ['sidebar', 'Sidebar']])),
        settingRow('Pinned site size', 'Choose how many pinned sites fit in each row.', selectSetting('pinSize', [['large', 'Large'], ['medium', 'Medium'], ['small', 'Small']])),
        settingRow('Live tab limit', 'Older background tabs sleep when you switch tabs above this limit.', numberSetting('maxLiveTabs', 12, 0, 168)),
        settingRow('Keep pinned sites awake', 'Exclude pinned sites from automatic tab sleeping.', toggleSetting('keepPinnedAppsAwake', true)),
        settingRow('Tab groups', 'Organize related tabs together. Drag a tab onto a group to move it.', button('New group', 'secondary-button', () => editGroup())),
        settingRow('Pinned sites', 'Pin the current page using the pin button in the toolbar.', node('span', 'status-line', `${state.pins.length} pinned`))
      ));
    } else if (settingsSection === 'appearance') {
      section.append(node('p', 'section-intro', 'The same clean canvas, in light or dark.'), card(
        settingRow('Theme', 'Follow Windows, or choose your own appearance.', selectSetting('theme', [['system', 'System'], ['light', 'Light'], ['dark', 'Dark']])),
        settingRow('Sidebar', 'Hide the sidebar for more space. Ctrl+Shift+S brings it back.', button('Toggle sidebar', 'secondary-button', toggleSidebar))
      ));
    } else if (settingsSection === 'cloud') renderCloudSettings(section);
    else if (settingsSection === 'aero') {
      const info = node('div', 'card-body');
      info.append(node('p', 'status-line', state.cloud.aeroConfigured ? 'Breeze Cloud is configured for Aero.' : 'Aero is not configured in this build.'));
      const note = node('p', 'section-intro', 'Aero uses Breeze Cloud. Your request and the current page’s relevant context are sent when you ask. Additional context below is optional.');
      section.append(note, card(info), card(
        settingRow('Recent browsing history', 'Allow Aero to use recent visits as context.', toggleSetting('aiIncludeHistory')),
        settingRow('Bookmarks', 'Allow Aero to use your saved pages as context.', toggleSetting('aiIncludeBookmarks')),
        settingRow('Open tabs', 'Allow Aero to see other open tabs.', toggleSetting('aiIncludeOpenTabs')),
        settingRow('Conversation context', 'Include earlier messages in the current Aero chat.', toggleSetting('aiUseChatHistory', true))
      ));
      const instructions = node('div', 'card-body'); const label = node('label', 'form-label', 'Custom instructions'); const input = node('textarea'); input.id = 'ai-instructions'; input.value = state.settings.aiInstructions || ''; input.placeholder = 'How would you like Aero to help?'; label.append(input);
      const save = button('Save instructions', 'secondary-button', async () => { const result = await run('settings:update', { aiInstructions: input.value }); if (result !== null) showToast('Instructions saved.'); }); instructions.append(label, node('br'), save); section.append(card(instructions));
    } else if (settingsSection === 'privacy') {
      section.append(node('p', 'section-intro', 'You control what’s saved and what leaves your browser.'), card(
        settingRow('Block ads & trackers', 'Apply Breeze’s built-in request blocking to web pages.', toggleSetting('adblockEnabled', true)),
        settingRow('Website notifications', 'Let websites ask to send notifications. Each site still needs your permission.', toggleSetting('webNotifications', true)),
        settingRow('Password vault', 'Manage passwords encrypted on this Windows device. Passwords never sync to Breeze Cloud.', button('Open vault', 'secondary-button', () => openPage('passwords'))),
        settingRow('Browsing history', 'Review and clear saved browsing history.', button('View history', 'secondary-button', () => openPage('history'))),
        settingRow('Website data & permissions', 'Clear cookies, cache, and site permissions. You’ll be signed out of websites.', button('Clear website data', 'secondary-button', () => run('browser:clearData')))
      ));
      const body = node('div', 'card-body'); body.append(node('p', 'section-intro', 'Cloud sync is off until you enable individual categories. Website logins, cookies, and the password vault stay on this device. Aero requests are processed by Breeze Cloud and its AI provider.')); section.append(card(body));
    } else if (settingsSection === 'reminders') {
      section.append(node('p', 'section-intro', 'Reminders are delivered while Breeze is running. Don’t use reminders for emergencies or safety-critical needs.'), button('Set a reminder', 'primary-button', reminderDialog), node('br'), node('br'));
      if (!state.reminders.length) section.append(emptyState('bell', 'Nothing to remember yet', 'Add a reminder here, or ask Aero to remind you.'));
      else { const list = node('div', 'item-list'); state.reminders.forEach((item) => {
        const row = node('div', 'list-item'); const copy = node('div', 'item-main'); copy.append(node('span', 'item-title', item.text || item.title), node('span', 'item-meta', `${dateText(item.dueAt || item.fireAt, true)}${item.fired || item.completed ? ' · Completed' : ''}`));
        row.append(icon('bell'), copy, iconButton('Remove reminder', 'close', () => run('reminder:remove', { id: item.id }))); list.append(row);
      }); section.append(list); }
    } else {
      const about = node('div', 'card-body'); about.append(node('h3', '', 'Breeze for Windows'), node('p', 'status-line', `Version ${state.version || 'unavailable'} · Chromium`), node('p', 'section-intro', 'The Breeze experience, powered by Chromium on Windows and Aero through Breeze Cloud.'), button('What’s new', 'secondary-button', () => openPage('updates')), button('Keyboard shortcuts', 'quiet-button', shortcutsDialog)); section.append(card(about));
      const platform = node('div', 'card-body'); platform.append(node('h3', '', 'Windows edition'), node('p', 'section-intro', 'This Windows release is unsigned. Passwords use Windows DPAPI encryption and explicit, site-matched filling. Apple Vision OCR, macOS dictation, and Apple FairPlay playback are not available. Images attached to Aero are sent as image context.'), node('p', 'section-intro', 'Updates are installed manually from a versioned Windows release. This edition does not use the macOS signed auto-updater.'), button('Check Windows releases', 'secondary-button', () => run('browser:update'))); section.append(card(platform));
    }
    layout.append(rail, section); page.append(layout); return page;
  }
  function renderCloudSettings(section) {
    const cloud = state.cloud || {};
    if (state.development && !cloud.configured) {
      const body = node('div', 'card-body'); body.append(node('h3', '', 'Breeze Cloud isn’t configured'), node('p', 'section-intro', 'This Windows test build is focused on the browser. Email and Google sign-in, account creation, and cloud sync are unavailable. No account information is needed.'), node('p', 'status-line', 'Tabs, bookmarks, history, downloads, local passwords, split view, and reminders work without a Breeze Cloud account.')); section.append(card(body)); return;
    }
    section.append(node('p', 'section-intro', 'Your account is optional. Signing in alone does not upload browser data. Each sync category starts off and only syncs after you turn it on.'));
    if (!cloud.account && !cloud.signedIn) {
      const body = node('div', 'card-body'); const form = node('form', 'stack-form'); const fields = node('div', 'form-grid');
      const email = textField('Email address', 'cloud-email', 'email'); email.input.autocomplete = 'username'; email.input.required = true;
      const password = textField('Password', 'cloud-password', 'password'); password.input.autocomplete = 'current-password'; password.input.minLength = 8; password.input.required = true;
      fields.append(email.wrapper, password.wrapper); form.append(fields);
      const controls = node('div', 'button-row');
      const signIn = button('Sign in', 'primary-button'); signIn.type = 'submit'; signIn.id = 'cloud-signin-button'; signIn.disabled = cloudAuthBusy;
      const signUp = button('Create account', 'secondary-button', () => authenticate('cloud:signUp')); signUp.id = 'cloud-signup-button'; signUp.disabled = cloudAuthBusy;
      const google = button('Continue with Google', 'secondary-button', () => run('cloud:google')); google.id = 'cloud-google-button'; google.disabled = cloudAuthBusy;
      controls.append(signIn, signUp, google); form.append(controls);
      const status = node('div', 'status-line', cloud.error || ''); status.id = 'cloud-form-status'; status.setAttribute('role', 'status'); if (cloud.error) status.classList.add('error-text'); form.append(status);
      const authenticate = async (action) => {
        if (cloudAuthBusy || !form.reportValidity()) return;
        cloudAuthBusy = true;
        signIn.disabled = true; signUp.disabled = true; google.disabled = true;
        status.textContent = action === 'cloud:signUp' ? 'Creating your account…' : 'Signing in…'; status.classList.remove('error-text');
        try {
          const result = await invoke(action, { email: email.input.value, password: password.input.value });
          password.input.value = ''; if ($('cloud-password')) $('cloud-password').value = '';
          if (result !== null) status.textContent = result?.message || (action === 'cloud:signUp' && !state.cloud.account ? 'Check your email to confirm your account.' : '');
        } catch (error) { password.input.value = ''; if ($('cloud-password')) $('cloud-password').value = ''; status.textContent = error.message; status.classList.add('error-text'); }
        finally { cloudAuthBusy = false; signIn.disabled = false; signUp.disabled = false; google.disabled = false; ['cloud-signin-button', 'cloud-signup-button', 'cloud-google-button'].forEach((id) => { if ($(id)) $(id).disabled = false; }); }
      };
      form.addEventListener('submit', (event) => { event.preventDefault(); authenticate('cloud:signIn'); });
      body.append(form, node('p', 'legal', 'By submitting this form or continuing with Google, you agree to the Breeze Terms of Service and Privacy Policy below.'));
      section.append(card(body));
    } else {
      const body = node('div', 'card-body'); body.append(node('h3', '', cloud.account?.email || cloud.email || 'Signed in'), node('p', cloud.error ? 'error-text' : 'status-line', cloud.error || (cloud.syncing ? 'Syncing…' : cloud.status && cloud.status !== 'Signed in' ? cloud.status : cloud.lastSync ? `Last synced ${dateText(cloud.lastSync, true)}` : 'Choose what to sync below.')));
      const actions = node('div', 'button-row'); const sync = button(cloud.syncing ? 'Syncing…' : 'Sync now', 'primary-button', () => run('cloud:sync')); sync.disabled = Boolean(cloud.syncing); actions.append(sync, button('Sign out', 'secondary-button', () => confirmDialog('Sign out of Breeze Cloud?', 'Your account will be disconnected. Selected synced copies of bookmarks, tabs, history, chats, and reminders are cleared from this Windows profile. Your cloud copies remain available when you sign in again.', 'Sign out', () => invoke('cloud:signOut')))); actions.append(button('Export cloud data', 'secondary-button', () => run('cloud:export')), button('Delete account', 'danger-button', deleteAccountDialog)); body.append(actions); section.append(card(body));
      const categories = node('div', 'card');
      [['bookmarks', 'Bookmarks', 'Saved page titles and URLs.'], ['tabs', 'Open tabs', 'Open tab titles and URLs.'], ['history', 'Browsing history', 'The websites you visit.'], ['chats', 'Aero chats', 'Conversation text and source links.'], ['reminders', 'Reminders', 'Reminder text and scheduled times.']].forEach(([key, label, hint]) => {
        const control = toggleSetting(`cloud-${key}`, false, (checked) => run('cloud:syncPreference', { key, enabled: checked }));
        control.querySelector('input').checked = Boolean((cloud.preferences || state.settings.cloudSync)?.[key]); categories.append(settingRow(label, hint, control));
      }); section.append(categories);
      section.append(node('p', 'section-intro', 'Passwords, cookies, and website storage stay on this device. Cloud copies are protected in transit but are not end-to-end encrypted. Turning off a category pauses syncing; it does not delete the existing cloud copy. Signing out clears selected synced copies from this Windows profile.'));
    }
    const legal = node('div', 'card-body legal');
    const privacy = node('details'); privacy.append(node('summary', '', 'Privacy Policy'));
    privacy.append(node('p', '', 'Supabase processes your email or Google account identity to sign you in. Breeze does not receive your Google password. Browser data syncs only for the categories you enable. The password vault, cookies, and website storage are never synced. Signing out clears selected synced copies from this device; cloud copies remain.'));
    privacy.append(node('p', '', 'When you send an Aero request, your prompt and relevant page, chat, or image context are sent through Breeze Cloud on Cloudflare and may be processed by OpenAI. Breeze does not sell personal data or use it for advertising. Websites receive normal connection data directly from your browser.'));
    privacy.append(node('p', '', 'You can export your cloud data or permanently delete your account in Settings. Deleting the account removes its cloud data. For other privacy requests, contact jake@winthenight.info.'));
    const terms = node('details'); terms.append(node('summary', '', 'Terms of Service'), node('p', '', 'Breeze Cloud accounts are optional. You are responsible for securing your account and device. Enable only the data categories you want stored with your account. You can export or delete account data in Settings. Turning off sync does not remove an existing cloud copy.'), node('p', '', 'Aero can return incomplete or inaccurate information. Verify important claims yourself. Breeze and connected services may change or be unavailable. Do not rely on Aero or reminders for emergencies or safety-critical needs.'), node('p', '', 'Effective September 25, 2026. Questions: jake@winthenight.info.'));
    legal.append(privacy, terms); section.append(card(legal));
  }
  function searchInput(placeholder, onInput) {
    const input = node('input', 'search-field'); input.type = 'search'; input.id = 'page-search'; input.placeholder = placeholder; input.setAttribute('aria-label', placeholder); input.value = query; input.addEventListener('input', () => { query = input.value; onInput(); }); return input;
  }
  function matchesQuery(item) { return !query || `${item.title || ''} ${item.url || ''} ${item.username || ''}`.toLowerCase().includes(query.toLowerCase()); }
  function historyPage() {
    const clear = button('Clear history', 'secondary-button', () => confirmDialog('Clear browsing history?', 'This removes saved browsing history from this Windows device. Your bookmarks and website logins are kept.', 'Clear history', () => invoke('history:clear'))); clear.disabled = !state.history.length;
    const page = pageBase('History', 'Pick up where you left off.', clear);
    const tabs = node('div', 'segmented'); [['browsing', 'Browsing'], ['chats', 'Breeze AI chats']].forEach(([key, title]) => tabs.append(button(title, historySection === key ? 'active' : '', () => { historySection = key; query = ''; renderPage(true); })));
    page.append(tabs, searchInput(historySection === 'chats' ? 'Search saved chats' : 'Search browsing history', () => renderPage(true)));
    const items = (historySection === 'chats' ? state.chats : state.history).filter(matchesQuery);
    if (!items.length) page.append(emptyState(historySection === 'chats' ? 'compose' : 'history', query ? 'No matches' : historySection === 'chats' ? 'No saved chats yet' : 'A fresh start', query ? 'Try a different search.' : historySection === 'chats' ? 'Your conversations with Aero will appear here.' : 'Pages you visit will appear here.'));
    else {
      const list = node('div', 'item-list'); let previousDay = '';
      items.slice(0, 500).forEach((item) => {
        const day = dateText(item.ts || item.timestamp || item.createdAt || item.updatedAt);
        if (day && day !== previousDay) { list.append(node('h2', 'date-label', day)); previousDay = day; }
        const row = node('div', 'list-item');
        const open = button('', 'item-main', () => historySection === 'chats' ? openAssistant(item.id) : navigate(item.url));
        open.append(node('span', 'item-title', item.title || hostName(item.url) || 'Aero chat'), node('span', 'item-meta', historySection === 'chats' ? `${item.messages?.length || 0} messages` : item.url));
        row.append(historySection === 'chats' ? icon('compose') : siteMark(item), open); list.append(row);
      }); page.append(list);
      if (items.length > 500) page.append(node('p', 'status-line', 'Showing the first 500 matches. Search to narrow your history.'));
    }
    return page;
  }
  function bookmarksPage() {
    const page = pageBase('Bookmarks', 'Good things, kept close.', button('Add bookmark', 'primary-button', bookmarkDialog));
    page.append(searchInput('Search bookmarks', () => renderPage(true)));
    const items = state.bookmarks.filter(matchesQuery);
    if (!items.length) page.append(emptyState('bookmark', query ? 'No matches' : 'Save something worth keeping', query ? 'Try a different search.' : 'Click the bookmark in the toolbar, or press Ctrl+D.'));
    else { const list = node('div', 'item-list'); items.forEach((item) => {
      const row = node('div', 'list-item'); const open = button('', 'item-main', () => navigate(item.url)); open.append(node('span', 'item-title', item.title || hostName(item.url)), node('span', 'item-meta', item.url));
      row.append(siteMark(item), open, iconButton('Remove bookmark', 'trash', () => run('bookmark:remove', { id: item.id, url: item.url }))); list.append(row);
    }); page.append(list); }
    return page;
  }
  function formatBytes(bytes) { const value = Number(bytes) || 0; if (value < 1024) return `${value} B`; if (value < 1048576) return `${(value / 1024).toFixed(1)} KB`; return `${(value / 1048576).toFixed(1)} MB`; }
  function downloadsPage() {
    const page = pageBase('Downloads', 'Files you’ve brought along.');
    if (!state.downloads.length) page.append(emptyState('download', 'No downloads yet', 'Files you download from the web will appear here.'));
    else { const list = node('div', 'item-list'); state.downloads.forEach((item) => {
      const row = node('div', 'list-item'); const info = node('div', 'item-main'); const status = item.state || item.status || 'pending';
      const complete = status === 'completed' || status === 'complete'; const running = ['progressing', 'downloading', 'pending', 'paused'].includes(status);
      info.append(node('span', 'item-title', item.filename || item.name || 'Download'), node('span', 'item-meta', `${status.charAt(0).toUpperCase() + status.slice(1)} · ${formatBytes(item.receivedBytes || item.received || item.totalBytes)}${running && item.totalBytes ? ` of ${formatBytes(item.totalBytes)}` : ''}`));
      if (running) { const progress = node('progress', 'download-progress'); if (item.totalBytes) { progress.max = item.totalBytes; progress.value = item.receivedBytes || item.received || 0; } progress.setAttribute('aria-label', 'Download progress'); info.append(progress); }
      const actions = node('div', 'button-row');
      if (complete) actions.append(button('Open', 'secondary-button', () => run('downloads:open', { id: item.id })), iconButton('Show in folder', 'folder', () => run('downloads:show', { id: item.id })));
      if (running) actions.append(iconButton('Cancel download', 'close', () => run('downloads:cancel', { id: item.id })));
      row.append(icon('download'), info, actions); list.append(row);
    }); page.append(list); }
    return page;
  }
  function passwordsPage() {
    const page = pageBase('Password vault', 'Encrypted on this Windows device. Never synced to Breeze Cloud.', button('Add password', 'primary-button', passwordDialog));
    page.append(searchInput('Search saved passwords', () => renderPage(true)));
    const items = state.passwords.filter(matchesQuery);
    if (!items.length) page.append(emptyState('key', query ? 'No matches' : 'Your vault is empty', query ? 'Try a site or username.' : 'Save a website login here, then fill it from the Breeze menu while visiting that site.'));
    else { const list = node('div', 'item-list'); items.forEach((item) => {
      const row = node('div', 'list-item'); const info = node('div', 'item-main'); info.append(node('span', 'item-title', item.title || hostName(item.url)), node('span', 'item-meta', `${item.username || 'No username'} · ${hostName(item.url)}`));
      const controls = node('div', 'button-row'); controls.append(iconButton('Reveal password', 'eye', () => revealPassword(item)), iconButton('Open website to fill login', 'key', () => { navigate(item.url || item.origin, true); showToast('Use More → Fill a saved password when the website’s sign-in page is open.'); }), iconButton('Delete password', 'trash', () => confirmDialog('Delete saved password?', `Remove the saved login for ${hostName(item.url) || item.title}?`, 'Delete password', () => invoke('passwords:remove', { id: item.id }))));
      row.append(siteMark(item), info, controls); list.append(row);
    }); page.append(list); }
    return page;
  }
  function onboardingPage() {
    const page = node('section', 'onboarding'); const logo = node('img'); logo.src = 'assets/icon.png'; logo.alt = 'Breeze';
    page.append(logo, node('h1', '', state.development ? 'Welcome to Breeze Test.' : 'Welcome to Breeze.'), node('p', '', 'A little less noise. A little more possibility. Your browser, with a helpful companion along for the ride.'));
    const features = node('div', 'onboarding-features');
    [['sidebar', 'Room to think', 'Your tabs and favorite sites, right where you need them.'], ['search', state.development && aeroUnavailable() ? 'Aero, later' : 'Meet Aero', state.development && aeroUnavailable() ? 'Aero isn’t configured in this browser-focused test build.' : 'Ask questions, explore sources, and make sense of the web.'], ['shield', 'Your browsing, your choice', 'Keep your data local, or choose what to sync.']].forEach(([name, title, description]) => { const feature = node('div', 'onboarding-feature'); feature.append(icon(name), node('h2', '', title), node('p', '', description)); features.append(feature); });
    const actions = node('div', 'button-row');
    const finish = async (settings) => { const result = await run('settings:update', { hasOnboarded: true }); if (result !== null) { if (settings) settingsSection = 'cloud'; openPage(settings ? 'settings' : 'newtab'); } };
    actions.append(button('Start exploring', 'primary-button', () => finish(false))); if (!state.development || state.cloud.configured) actions.append(button('Set up Breeze Cloud', 'secondary-button', () => finish(true)));
    page.append(features, actions, node('p', 'legal', state.development && !state.cloud.configured ? 'Windows test build. Aero and Breeze Cloud aren’t configured. Your browsing data stays in this test profile.' : 'Breeze Cloud is optional. Aero requests send relevant context to Breeze Cloud; sync stays off until you choose to enable it.'));
    return page;
  }
  function updatesPage() {
    const page = pageBase('What’s new', 'A familiar Breeze. A new home.');
    const body = node('div', 'card-body'); body.append(node('p', 'release-version', `Breeze ${state.version || ''} for Windows`), node('h2', '', 'Hello, Windows.'));
    const list = node('ul', 'release-notes'); ['Breeze’s clean canvas, pinned sites, vertical tabs, and tab groups.', 'Chromium-powered pages with split view, downloads, bookmarks, and browsing history.', 'Aero with Breeze Cloud, page context, research tasks, and reminders.', 'Optional Breeze Cloud account and category-by-category sync.', 'An encrypted, device-local password vault.'].forEach((text) => list.append(node('li', '', text)));
    body.append(list, node('p', 'status-line', 'This unsigned Windows release uses Chromium. Apple Vision OCR, native macOS dictation, and Apple FairPlay playback are not included. Updates are installed manually from a versioned Windows release.')); page.append(card(body)); return page;
  }
  function openAssistant(id) { localAssistantFullscreen = false; return run('assistant:open', id ? { id, visible: true } : { visible: true }); }
  async function sendAssistant(text) {
    if (!String(text).trim()) return;
    if (aeroUnavailable()) { showToast(aeroUnavailableReason()); return null; }
    closePalette();
    const result = await run('assistant:send', { text: String(text).trim(), tabIds: [...mentionedTabs] });
    if (result !== null) { mentionedTabs.clear(); renderAssistant(); }
    return result;
  }
  function renderAssistant() {
    const assistant = state.assistant || {}; const unavailable = aeroUnavailable();
    $('assistant').hidden = !assistant.visible;
    const fullscreen = Boolean(assistant.fullscreen || localAssistantFullscreen);
    $('app').classList.toggle('assistant-fullscreen', Boolean(assistant.visible && fullscreen));
    $('assistant-expand').title = fullscreen ? 'Return to sidebar' : 'Expand Aero';
    const fingerprint = JSON.stringify([assistant.messages, assistant.running, assistant.chatId, assistant.visible, unavailable]);
    if (fingerprint !== assistantFingerprint) {
      assistantFingerprint = fingerprint;
      const container = $('assistant-messages');
      const atBottom = container.scrollTop + container.clientHeight >= container.scrollHeight - 75;
      const previousScroll = container.scrollTop;
      container.replaceChildren();
      const messages = Array.isArray(assistant.messages) ? assistant.messages : [];
      if (!messages.length) {
        const empty = node('div', 'assistant-empty'); const logo = node('img'); logo.src = 'assets/nav-icon.png'; logo.alt = '';
        empty.append(logo, node('h2', '', unavailable ? 'Aero isn’t configured' : 'A little help from Aero.'), node('p', '', unavailable ? (state.development ? 'This test build is focused on browsing. Aero and its research tasks will be available once Breeze Cloud is configured.' : aeroUnavailableReason()) : 'Ask a question, understand a page, or explore something new.'));
        if (!unavailable && activeTab() && !isInternalURL(activeTab().url)) empty.append(button('Summarize this page', 'quiet-button', () => sendAssistant('/summarize')));
        if (!unavailable) empty.append(button('Research a topic', 'quiet-button', () => { $('assistant-input').value = '/research '; $('assistant-input').focus(); }));
        container.append(empty);
      } else messages.forEach((message) => {
        const role = message.role === 'user' ? 'user' : ['system', 'tool', 'status'].includes(message.role) ? 'system' : 'assistant';
        const bubble = node('article', `message ${role}`); bubble.setAttribute('aria-label', role === 'user' ? 'You' : role === 'system' ? 'Aero activity' : 'Aero');
        const text = typeof message.text === 'string' ? message.text : typeof message.content === 'string' ? message.content : '';
        if (role === 'assistant') appendMarkdown(bubble, text); else bubble.textContent = text;
        container.append(bubble);
      });
      container.scrollTop = atBottom ? container.scrollHeight : previousScroll;
    }
    $('assistant-status').textContent = unavailable ? aeroUnavailableReason() : assistant.error || assistant.status || (assistant.running ? 'Aero is working…' : '');
    $('assistant-status').classList.toggle('error-text', Boolean(assistant.error));
    $('assistant-send').replaceChildren(icon(assistant.running ? 'stop' : 'send'));
    $('assistant-send').disabled = unavailable && !assistant.running; $('assistant-input').disabled = unavailable; $('assistant-input').placeholder = unavailable ? 'Aero isn’t configured' : 'Ask anything…';
    $('assistant-send').title = unavailable && !assistant.running ? aeroUnavailableReason() : assistant.running ? 'Stop response' : 'Send'; $('assistant-send').setAttribute('aria-label', $('assistant-send').title);
    $('assistant-attach').disabled = unavailable || Boolean(assistant.running); $('assistant-attach').title = unavailable ? aeroUnavailableReason() : 'Attach image';
    const context = $('assistant-context'); context.replaceChildren();
    const tab = activeTab();
    if (tab && !isInternalURL(tab.url)) { const pill = node('span', 'context-pill'); pill.title = 'The current page is included when you ask Aero.'; pill.append(icon('globe'), node('span', '', tab.title || hostName(tab.url))); context.append(pill); }
    for (const id of [...mentionedTabs]) {
      const mentioned = state.tabs.find((item) => item.id === id);
      if (!mentioned) { mentionedTabs.delete(id); continue; }
      const pill = node('span', 'context-pill'); pill.append(node('span', '', mentioned.title || hostName(mentioned.url)), iconButton('Remove tab context', 'close', () => { mentionedTabs.delete(id); renderAssistant(); })); context.append(pill);
    }
    const attachments = $('assistant-attachments'); attachments.replaceChildren();
    for (const attachment of assistant.attachments || []) {
      const pill = node('span', 'context-pill'); pill.append(icon('attach'), node('span', '', attachment.name || 'Image'), iconButton('Remove attachment', 'close', () => run('assistant:attach', { removeId: attachment.id }))); attachments.append(pill);
    }
  }
  function appendInline(parent, text) {
    // A deliberately small Markdown subset. DOM creation keeps responses inert;
    // links can only dispatch http(s) navigation through the main process.
    const pattern = /\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)|\*\*([^*\n]+)\*\*|`([^`\n]+)`|(https?:\/\/[^\s<>]+)/g;
    let last = 0; let match;
    while ((match = pattern.exec(text))) {
      if (match.index > last) parent.append(document.createTextNode(text.slice(last, match.index)));
      if (match[1] || match[5]) {
        const href = match[2] || match[5];
        const anchor = node('a', '', match[1] || href); anchor.href = href; anchor.rel = 'noopener noreferrer';
        anchor.addEventListener('click', (event) => { event.preventDefault(); navigate(href, true); }); parent.append(anchor);
      } else if (match[3]) parent.append(node('strong', '', match[3]));
      else parent.append(node('code', '', match[4]));
      last = pattern.lastIndex;
    }
    if (last < text.length) parent.append(document.createTextNode(text.slice(last)));
  }
  function appendMarkdown(parent, text) {
    const sections = text.split(/```/);
    sections.forEach((section, index) => {
      if (index % 2) { const code = section.replace(/^[a-zA-Z0-9#+.-]*\n/, ''); parent.append(node('pre', '', code)); return; }
      let list = null;
      for (const block of section.split(/\n{2,}/)) {
        if (!block.trim()) continue;
        if (/^#{1,4}\s/.test(block)) { const title = node('h3'); appendInline(title, block.replace(/^#{1,4}\s/, '')); parent.append(title); list = null; }
        else if (block.split('\n').every((line) => /^\s*(?:[-*]|\d+\.)\s/.test(line))) {
          list = node(/^\s*\d+\./.test(block) ? 'ol' : 'ul');
          block.split('\n').forEach((line) => { const item = node('li'); appendInline(item, line.replace(/^\s*(?:[-*]|\d+\.)\s/, '')); list.append(item); }); parent.append(list);
        } else { const paragraph = node('p'); appendInline(paragraph, block); parent.append(paragraph); list = null; }
      }
    });
  }
  function updatePalette(input) {
    const value = input.value;
    const slash = value.match(/^\/([a-z]*)$/i);
    const mention = value.match(/(?:^|\s)@([^@\n]*)$/);
    const palette = $('task-palette'); palette.replaceChildren();
    if (slash) {
      const options = tasks.filter((task) => task.slug.startsWith(slash[1].toLowerCase()));
      if (!options.length) return closePalette();
      options.forEach((task) => {
        const entry = button('', '', () => { input.value = `/${task.slug} `; closePalette(); input.focus(); });
        const copy = node('span'); copy.append(node('strong', '', task.title), node('small', '', task.description)); entry.append(icon(task.icon), copy); entry.setAttribute('role', 'option'); palette.append(entry);
      });
    } else if (mention) {
      const options = state.tabs.filter((tab) => !isInternalURL(tab.url) && `${tab.title} ${tab.url}`.toLowerCase().includes(mention[1].toLowerCase())).slice(0, 8);
      if (!options.length) return closePalette();
      options.forEach((tab) => {
        const entry = button('', '', () => { mentionedTabs.add(tab.id); input.value = value.slice(0, value.lastIndexOf('@')) + `@${tab.title || hostName(tab.url)} `; closePalette(); input.focus(); renderAssistant(); });
        const copy = node('span'); copy.append(node('strong', '', tab.title || hostName(tab.url)), node('small', '', hostName(tab.url))); entry.append(siteMark(tab), copy); entry.setAttribute('role', 'option'); palette.append(entry);
      });
    } else return closePalette();
    palette.hidden = false;
    const rect = input.getBoundingClientRect(); const height = palette.offsetHeight;
    palette.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - palette.offsetWidth - 8))}px`;
    palette.style.top = `${rect.top > height + 16 ? rect.top - height - 10 : Math.min(rect.bottom + 10, window.innerHeight - height - 8)}px`;
    scheduleLayout();
  }
  function closePalette() { if (!$('task-palette').hidden) { $('task-palette').hidden = true; $('task-palette').replaceChildren(); scheduleLayout(); } }
  function autoGrow(input) { input.style.height = 'auto'; input.style.height = `${Math.min(input.scrollHeight, 135)}px`; }
  function openMenu(items, anchor, event) {
    closePalette(); const menu = $('context-menu'); menu.replaceChildren(); menuAnchor = anchor;
    items.forEach((item) => {
      if (!item) { menu.append(node('div', 'menu-separator')); return; }
      const entry = button('', '', () => { closeMenu(); item.fn(); }, item.icon);
      entry.append(node('span', '', item.label)); if (item.shortcut) entry.append(node('span', 'menu-shortcut', item.shortcut));
      entry.disabled = Boolean(item.disabled); entry.setAttribute('role', 'menuitem'); menu.append(entry);
    });
    menu.hidden = false;
    const rect = anchor.getBoundingClientRect();
    const x = event?.clientX ?? rect.left; const y = event?.clientY ?? rect.bottom + 6;
    menu.style.left = `${Math.max(8, Math.min(x, window.innerWidth - menu.offsetWidth - 8))}px`;
    menu.style.top = `${Math.max(8, Math.min(y, window.innerHeight - menu.offsetHeight - 8))}px`;
    menu.querySelector('button:not(:disabled)')?.focus(); scheduleLayout();
  }
  function closeMenu() {
    if ($('context-menu').hidden) return;
    $('context-menu').hidden = true; $('context-menu').replaceChildren();
    if (menuAnchor?.isConnected && document.activeElement === document.body) menuAnchor.focus(); menuAnchor = null;
    scheduleLayout();
  }
  function browserMenu() {
    const tab = activeTab(); const webpage = tab && !isInternalURL(tab.url);
    openMenu([
      { label: 'New tab', icon: 'plus', shortcut: 'Ctrl+T', fn: () => run('tab:new') },
      { label: 'New tab group', icon: 'folder', fn: () => editGroup() },
      null,
      { label: 'Find in page', icon: 'search', shortcut: 'Ctrl+F', disabled: !webpage, fn: showFind },
      { label: 'Zoom in', icon: 'plus', shortcut: 'Ctrl++', disabled: !webpage, fn: () => run('browser:zoom', { delta: 0.1 }) },
      { label: 'Zoom out', icon: 'minimize', shortcut: 'Ctrl+−', disabled: !webpage, fn: () => run('browser:zoom', { delta: -0.1 }) },
      { label: 'Actual size', icon: 'maximize', shortcut: 'Ctrl+0', disabled: !webpage, fn: () => run('browser:zoom', { value: 0 }) },
      { label: 'Fill a saved password', icon: 'key', disabled: !webpage, fn: fillCurrentPassword },
      null,
      { label: 'History', icon: 'history', shortcut: 'Ctrl+H', fn: () => openPage('history') },
      { label: 'Bookmarks', icon: 'bookmark', fn: () => openPage('bookmarks') },
      { label: 'Downloads', icon: 'download', shortcut: 'Ctrl+Shift+J', fn: () => openPage('downloads') },
      { label: 'Settings', icon: 'settings', fn: () => openPage('settings') },
      { label: 'Keyboard shortcuts', icon: 'help', fn: shortcutsDialog }
    ], $('browser-menu'));
  }
  function workspaceMenu() {
    openMenu([
      { label: 'New tab', icon: 'plus', shortcut: 'Ctrl+T', fn: () => run('tab:new') },
      { label: 'Ask Aero', icon: 'compose', shortcut: 'Ctrl+J', fn: () => openAssistant() },
      { label: 'Breeze Cloud', icon: 'cloud', fn: () => { settingsSection = 'cloud'; openPage('settings'); } },
      null,
      { label: 'Bookmarks', icon: 'bookmark', fn: () => openPage('bookmarks') },
      { label: 'History', icon: 'history', fn: () => openPage('history') },
      { label: 'Downloads', icon: 'download', fn: () => openPage('downloads') },
      { label: 'Passwords', icon: 'key', fn: () => { run('passwords:list').then((result) => { if (Array.isArray(result)) { state.passwords = result; renderPage(true); } }); openPage('passwords'); } },
      null,
      { label: 'Settings', icon: 'settings', fn: () => openPage('settings') },
      { label: 'What’s new', icon: 'document', fn: () => openPage('updates') }
    ], $('workspace-button'));
  }
  function openDialog(title, body, submitText, onSubmit, destructive = false) {
    closeMenu(); closePalette();
    if ($('dialog').open) closeDialog();
    dialogReturnFocus = document.activeElement;
    $('dialog-title').textContent = title; $('dialog-body').replaceChildren(body); $('dialog-error').textContent = '';
    const cancel = button('Cancel', 'secondary-button', closeDialog); const submit = button(submitText, destructive ? 'danger-button' : 'primary-button'); submit.type = 'submit'; submit.id = 'dialog-submit';
    $('dialog-actions').replaceChildren(cancel, submit); dialogSubmit = onSubmit;
    $('dialog').showModal(); scheduleLayout();
    requestAnimationFrame(() => $('dialog-body').querySelector('input,textarea,select,button')?.focus());
  }
  function closeDialog() {
    if (!$('dialog').open) return;
    $('dialog').close(); $('dialog-body').replaceChildren(); $('dialog-error').textContent = ''; dialogSubmit = null;
    dialogReturnFocus?.isConnected && dialogReturnFocus.focus({ preventScroll: true }); dialogReturnFocus = null; scheduleLayout();
  }
  function confirmDialog(title, description, label, action) { openDialog(title, node('p', 'status-line', description), label, action, true); }
  function editGroup(group) {
    const form = node('div', 'stack-form'); const title = textField('Group name', 'group-title', 'text', group?.title || ''); title.input.required = true; title.input.maxLength = 60;
    const color = textField('Group color', 'group-color', 'color', /^#[\da-f]{6}$/i.test(group?.color || '') ? group.color : '#3aa6b9');
    form.append(title.wrapper, color.wrapper);
    openDialog(group ? 'Rename tab group' : 'New tab group', form, group ? 'Save' : 'Create group', () => invoke(group ? 'group:update' : 'group:create', { ...(group ? { id: group.id } : {}), title: title.input.value.trim(), color: color.input.value }));
  }
  function assignGroup(tab) {
    const body = node('div', 'stack-form'); const label = node('label', 'form-label', 'Choose a group'); const select = node('select'); select.id = 'assign-group';
    const none = node('option', '', 'No group'); none.value = ''; select.append(none);
    state.groups.forEach((group) => { const option = node('option', '', group.title); option.value = group.id; select.append(option); }); select.value = tab.groupId || ''; label.append(select); body.append(label);
    if (!state.groups.length) body.append(node('p', 'status-line', 'Create a group from the Breeze menu first.'));
    openDialog('Move tab to group', body, 'Move tab', () => invoke('group:assign', { tabId: tab.id, groupId: select.value || null }));
  }
  function deleteAccountDialog() {
    const body = node('div', 'stack-form');
    body.append(node('p', 'error-text', 'This permanently deletes your Breeze Cloud account and its cloud data. This cannot be undone. You will be signed out, and selected synced copies will be cleared from this Windows profile. Device-only passwords, cookies, and website storage are not deleted.'));
    body.append(node('p', 'status-line', 'Export anything you want to keep before continuing.'));
    const confirmation = textField('Type DELETE to confirm', 'cloud-delete-confirmation');
    confirmation.input.required = true; confirmation.input.pattern = 'DELETE'; confirmation.input.autocomplete = 'off'; confirmation.input.spellcheck = false;
    body.append(confirmation.wrapper);
    openDialog('Permanently delete your account?', body, 'Delete account permanently', () => {
      if (confirmation.input.value !== 'DELETE') throw new Error('Type DELETE exactly to continue.');
      return invoke('cloud:deleteAccount', { confirmation: 'DELETE' });
    }, true);
  }
  function bookmarkDialog() {
    const body = node('div', 'stack-form'); const title = textField('Name', 'bookmark-name'); const url = textField('Website address', 'bookmark-url', 'url'); url.input.required = true; url.input.placeholder = 'https://example.com'; body.append(title.wrapper, url.wrapper);
    openDialog('Add bookmark', body, 'Save bookmark', () => invoke('bookmark:add', { title: title.input.value.trim() || hostName(url.input.value), url: url.input.value.trim() }));
  }
  function passwordDialog() {
    const body = node('div', 'stack-form'); const site = textField('Website', 'vault-url', 'url'); site.input.placeholder = 'https://example.com'; site.input.required = true;
    const username = textField('Username or email', 'vault-username'); username.input.autocomplete = 'off';
    const password = textField('Password', 'vault-password', 'password'); password.input.required = true; password.input.autocomplete = 'new-password';
    body.append(site.wrapper, username.wrapper, password.wrapper, node('p', 'legal', 'Saved passwords are encrypted on this Windows device and never synced to Breeze Cloud.'));
    openDialog('Save a password', body, 'Save password', async () => {
      const result = await invoke('passwords:save', { url: site.input.value.trim(), username: username.input.value, password: password.input.value }); password.input.value = '';
      if (result !== null) { const list = await run('passwords:list'); if (Array.isArray(list)) { state.passwords = list; renderPage(true); } } return result;
    });
  }
  async function revealPassword(item) {
    const result = await run('passwords:reveal', { id: item.id });
    const password = typeof result === 'string' ? result : result?.password;
    if (typeof password !== 'string') return;
    const body = node('div'); body.append(node('p', 'status-line', `${item.username || ''} · ${hostName(item.url || item.origin)}`), node('div', 'secret-value', password), node('p', 'legal', 'Keep this password private. It is removed from this view when you close the dialog.'));
    openDialog('Saved password', body, 'Done', async () => true);
  }
  function fillCurrentPassword() {
    const tab = activeTab();
    if (!tab || isInternalURL(tab.url)) return;
    let origin; try { origin = new URL(tab.url).origin; } catch { return; }
    const matches = state.passwords.filter((item) => { try { return new URL(item.url || item.origin).origin === origin; } catch { return false; } });
    if (!matches.length) { showToast('There is no saved login for this site. Add one in the password vault.'); return; }
    const body = node('div', 'stack-form');
    const label = node('label', 'form-label', `Choose a saved login for ${hostName(tab.url)}`); const select = node('select');
    matches.forEach((item) => { const option = node('option', '', item.username || 'Saved login'); option.value = item.id; select.append(option); }); label.append(select); body.append(label);
    openDialog('Fill saved password', body, 'Fill login', () => invoke('passwords:fill', { id: select.value, tabId: tab.id }));
  }
  function reminderDialog() {
    const body = node('div', 'stack-form'); const text = textField('Remind me to', 'reminder-text'); text.input.required = true; text.input.maxLength = 1000;
    const date = textField('When', 'reminder-time', 'datetime-local'); date.input.required = true;
    const future = new Date(Date.now() + 30 * 60000); const local = new Date(future.getTime() - future.getTimezoneOffset() * 60000); date.input.value = local.toISOString().slice(0, 16);
    body.append(text.wrapper, date.wrapper, node('p', 'legal', 'Keep Breeze running to receive this reminder.'));
    openDialog('Set a reminder', body, 'Set reminder', () => {
      const when = new Date(date.input.value);
      if (Number.isNaN(when.getTime()) || when.getTime() <= Date.now()) throw new Error('Choose a time in the future.');
      return invoke('reminder:add', { text: text.input.value.trim(), dueAt: when.toISOString() });
    });
  }
  function shortcutsDialog() {
    const list = node('div', 'shortcut-list');
    [['New tab', 'Ctrl+T'], ['Close tab', 'Ctrl+W'], ['Focus address', 'Ctrl+L'], ['Ask Aero', 'Ctrl+J'], ['Toggle sidebar', 'Ctrl+Shift+S'], ['Find in page', 'Ctrl+F'], ['Bookmark page', 'Ctrl+D'], ['History', 'Ctrl+H'], ['Downloads', 'Ctrl+Shift+J'], ['Next tab', 'Ctrl+Tab'], ['Previous tab', 'Ctrl+Shift+Tab'], ['Reload page', 'Ctrl+R'], ['Back / forward', 'Alt+← / →'], ['Ask from a new tab', 'Enter'], ['Search from a new tab', 'Shift+Enter']].forEach(([title, key]) => list.append(node('span', '', title), node('kbd', '', key)));
    openDialog('Keyboard shortcuts', list, 'Done', async () => true);
  }
  function toggleSidebar() { $('app').classList.toggle('sidebar-hidden'); scheduleLayout(); }
  function showFind() { if (currentPage()) return; $('find-bar').hidden = false; $('find-input').focus(); $('find-input').select(); scheduleLayout(); }
  function find(forward = true, next = false) {
    const text = $('find-input').value;
    if (!text) return run('browser:find', { text: '', stop: true });
    return run('browser:find', { text, forward, findNext: next });
  }
  function closeFind() { $('find-bar').hidden = true; $('find-count').textContent = ''; run('browser:find', { text: '', stop: true }); scheduleLayout(); }
  function splitDialog() {
    if (state.splitTabId) return run('tab:activate', { id: state.activeTabId, split: false });
    const choices = state.tabs.filter((tab) => tab.id !== state.activeTabId && !isInternalURL(tab.url));
    const body = node('div', 'stack-form');
    if (choices.length) {
      const label = node('label', 'form-label', 'Choose a tab to open beside this one'); const select = node('select');
      choices.forEach((tab) => { const option = node('option', '', tab.title || hostName(tab.url)); option.value = tab.id; select.append(option); }); label.append(select); body.append(label);
      openDialog('Split view', body, 'Open split view', () => invoke('tab:activate', { id: select.value, split: true }));
    } else {
      const url = textField('Website to open beside this tab', 'split-url', 'text'); url.input.required = true; url.input.placeholder = 'Search or enter URL'; body.append(url.wrapper);
      openDialog('Split view', body, 'Open split view', () => invoke('tab:new', { url: url.input.value.trim(), split: true }));
    }
  }
  function rect(element) {
    const value = element.getBoundingClientRect();
    return { x: Math.round(value.x), y: Math.round(value.y), width: Math.max(0, Math.floor(value.width)), height: Math.max(0, Math.floor(value.height)) };
  }
  function scheduleLayout() {
    if (layoutFrame) return;
    layoutFrame = requestAnimationFrame(() => {
      layoutFrame = null;
      if (!bridge?.invoke) return;
      const content = rect($('browser-primary'));
      const hidden = Boolean(currentPage()) || $('app').classList.contains('assistant-fullscreen') || getComputedStyle($('content')).display === 'none';
      const payload = {
        ...content,
        width: hidden ? 0 : content.width,
        height: hidden ? 0 : content.height,
        split: !hidden && state.splitTabId ? { id: state.splitTabId, ...rect($('browser-secondary')) } : null,
        assistantWidth: $('assistant').hidden ? 0 : Math.round($('assistant').getBoundingClientRect().width),
        overlayOpen: $('dialog').open || !$('context-menu').hidden || !$('task-palette').hidden
      };
      const signature = JSON.stringify(payload);
      if (signature === lastLayout) return;
      lastLayout = signature;
      bridge.invoke('browser:layout', payload).catch(() => { lastLayout = ''; });
    });
  }
  function receiveEvent(event) {
    if (!event || typeof event !== 'object') return;
    const type = event.type || event.name; const payload = event.payload || event;
    if (type === 'state') receiveState(payload.state || payload);
    else if (['toast', 'error', 'notification'].includes(type)) showToast(payload.message || payload.text || (typeof payload.error === 'string' ? payload.error : '') || 'Breeze notification');
    else if (type === 'focus-address') { $('address').focus(); $('address').select(); }
    else if (type === 'find-open') showFind();
    else if (type === 'escape') { closeMenu(); closePalette(); if ($('dialog').open) closeDialog(); if (!$('find-bar').hidden) closeFind(); }
    else if (type === 'resize') scheduleLayout();
    else if (type === 'focus-newtab') $('newtab-input')?.focus();
    else if (type === 'focus-assistant') $('assistant-input').focus();
    else if (type === 'find-result' || type === 'found-in-page') { const result = payload.result || payload; $('find-count').textContent = result.matches ? `${result.activeMatchOrdinal || 0} / ${result.matches}` : 'No matches'; }
    else if (type === 'open-page' && INTERNAL_PAGES.has(payload.page)) openPage(payload.page);
    else if (type === 'assistant' || type === 'assistant-update') { state.assistant = { ...state.assistant, ...payload }; renderAssistant(); scheduleLayout(); }
    else if (type === 'reminder') showToast(payload.text || 'Your reminder is due.');
  }

  hydrateIcons();
  // Subscribe before any action. The main process owns the initial snapshot.
  if (bridge?.onState) bridge.onState(receiveState);
  if (bridge?.onEvent) bridge.onEvent(receiveEvent);
  $('workspace-button').addEventListener('click', workspaceMenu);
  $('browser-menu').addEventListener('click', browserMenu);
  $('sidebar-toggle').addEventListener('click', toggleSidebar);
  $('new-tab').addEventListener('click', () => run('tab:new'));
  $('go-back').addEventListener('click', () => run('tab:back', { id: state.activeTabId }));
  $('go-forward').addEventListener('click', () => run('tab:forward', { id: state.activeTabId }));
  $('reload').addEventListener('click', () => run('tab:reload', { id: state.activeTabId, stop: Boolean(activeTab()?.loading) }));
  $('address-form').addEventListener('submit', (event) => { event.preventDefault(); navigate($('address').value); $('address').blur(); });
  $('address').addEventListener('focus', () => $('address').select());
  $('address').addEventListener('input', () => updatePalette($('address')));
  $('page-info').addEventListener('click', () => {
    const tab = activeTab(); if (!tab || isInternalURL(tab.url)) return;
    const body = node('div'); body.append(node('p', 'status-line', tab.url), node('p', 'legal', tab.url.startsWith('https:') ? 'This page uses HTTPS. Always check the address before entering personal information.' : 'This page does not use HTTPS. Avoid entering passwords or other private information.'));
    openDialog('Page address', body, 'Done', async () => true);
  });
  $('pin-current').addEventListener('click', () => togglePin());
  $('bookmark-current').addEventListener('click', () => toggleBookmark());
  $('split-button').addEventListener('click', splitDialog);
  $('split-close').addEventListener('click', () => run('tab:activate', { id: state.activeTabId, split: false }));
  $('aero-toggle').addEventListener('click', () => run('assistant:open', { visible: !state.assistant.visible }));
  $('theme-toggle').addEventListener('click', cycleTheme);
  $('clock').addEventListener('click', () => { settingsSection = 'reminders'; openPage('settings'); });
  document.querySelectorAll('[data-page]').forEach((element) => element.addEventListener('click', () => openPage(element.dataset.page)));
  ['minimize', 'maximize', 'close'].forEach((action) => $(`window-${action}`).addEventListener('click', () => run(`window:${action}`)));
  $('assistant-close').addEventListener('click', () => { localAssistantFullscreen = false; run('assistant:open', { visible: false, fullscreen: false }); });
  $('assistant-new').addEventListener('click', () => { mentionedTabs.clear(); run('assistant:new'); });
  $('assistant-expand').addEventListener('click', () => { localAssistantFullscreen = !(state.assistant.fullscreen || localAssistantFullscreen); run('assistant:open', { visible: true, fullscreen: localAssistantFullscreen }); renderAssistant(); scheduleLayout(); });
  $('assistant-attach').addEventListener('click', () => run('assistant:attach'));
  $('assistant-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    if (state.assistant.running) { run('assistant:stop'); return; }
    const input = $('assistant-input'); const text = input.value.trim(); if (!text) return;
    input.value = ''; autoGrow(input); const result = await sendAssistant(text);
    if (result === null && !input.value) { input.value = text; autoGrow(input); }
  });
  $('assistant-input').addEventListener('input', () => { autoGrow($('assistant-input')); updatePalette($('assistant-input')); });
  $('assistant-input').addEventListener('keydown', (event) => { if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); $('assistant-form').requestSubmit(); } });
  $('find-input').addEventListener('input', () => find());
  $('find-input').addEventListener('keydown', (event) => { if (event.key === 'Enter') { event.preventDefault(); find(!event.shiftKey, true); } });
  $('find-next').addEventListener('click', () => find(true, true));
  $('find-previous').addEventListener('click', () => find(false, true));
  $('find-close').addEventListener('click', closeFind);
  $('dialog-close').addEventListener('click', closeDialog);
  $('dialog').addEventListener('cancel', (event) => { event.preventDefault(); closeDialog(); });
  $('dialog-form').addEventListener('submit', async (event) => {
    event.preventDefault(); if (!dialogSubmit) return;
    const submit = $('dialog-submit'); if (submit.disabled) return;
    const handler = dialogSubmit;
    submit.disabled = true; $('dialog-error').textContent = '';
    try { const result = await handler(); if (result !== null && dialogSubmit === handler) closeDialog(); }
    catch (error) { $('dialog-error').textContent = error.message || 'The action could not be completed.'; }
    finally { if (submit.isConnected) submit.disabled = false; }
  });
  document.addEventListener('pointerdown', (event) => {
    if (!$('context-menu').hidden && !$('context-menu').contains(event.target) && !menuAnchor?.contains(event.target)) closeMenu();
    if (!$('task-palette').hidden && !$('task-palette').contains(event.target) && !['address', 'newtab-input', 'assistant-input'].includes(event.target.id)) closePalette();
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      if (!$('context-menu').hidden) { closeMenu(); event.preventDefault(); return; }
      if (!$('task-palette').hidden) { closePalette(); event.preventDefault(); return; }
      if (!$('find-bar').hidden) { closeFind(); event.preventDefault(); return; }
      if (document.activeElement === $('address')) { $('address').blur(); renderToolbar(); }
    }
    const menu = !$('context-menu').hidden ? $('context-menu') : !$('task-palette').hidden ? $('task-palette') : null;
    if (menu && ['ArrowUp', 'ArrowDown'].includes(event.key)) {
      event.preventDefault(); const choices = [...menu.querySelectorAll('button:not(:disabled)')]; const index = choices.indexOf(document.activeElement); const next = (index + (event.key === 'ArrowDown' ? 1 : -1) + choices.length) % choices.length; choices[next]?.focus(); return;
    }
    if ($('dialog').open) return;
    const ctrl = event.ctrlKey || event.metaKey;
    const key = event.key.toLowerCase();
    if (ctrl && key === 'l') { event.preventDefault(); $('address').focus(); $('address').select(); }
    else if (ctrl && key === 't') { event.preventDefault(); run('tab:new'); }
    else if (ctrl && key === 'w') { event.preventDefault(); run('tab:close', { id: state.activeTabId }); }
    else if (ctrl && key === 'j') { event.preventDefault(); if (event.shiftKey) openPage('downloads'); else openAssistant().then(() => $('assistant-input').focus()); }
    else if (ctrl && key === 's' && event.shiftKey) { event.preventDefault(); toggleSidebar(); }
    else if (ctrl && key === 'h') { event.preventDefault(); openPage('history'); }
    else if (ctrl && key === 'd') { event.preventDefault(); toggleBookmark(); }
    else if (ctrl && key === 'f') { event.preventDefault(); showFind(); }
    else if (ctrl && key === 'r') { event.preventDefault(); run('tab:reload', { id: state.activeTabId }); }
    else if (ctrl && ['=', '+', '-', '0'].includes(key)) { event.preventDefault(); run('browser:zoom', key === '0' ? { value: 0 } : { delta: key === '-' ? -0.1 : 0.1 }); }
    else if (ctrl && key === 'tab') { event.preventDefault(); const index = state.tabs.findIndex((tab) => tab.id === state.activeTabId); const next = (index + (event.shiftKey ? -1 : 1) + state.tabs.length) % state.tabs.length; if (state.tabs[next]) run('tab:activate', { id: state.tabs[next].id }); }
    else if (ctrl && /^[1-9]$/.test(key)) { event.preventDefault(); const index = key === '9' ? state.tabs.length - 1 : Number(key) - 1; if (state.tabs[index]) run('tab:activate', { id: state.tabs[index].id }); }
    else if (event.altKey && ['ArrowLeft', 'ArrowRight'].includes(event.key)) { event.preventDefault(); run(event.key === 'ArrowLeft' ? 'tab:back' : 'tab:forward', { id: state.activeTabId }); }
  });
  const divider = $('split-divider');
  let draggingSplit = false;
  function setSplitRatio(ratio) { splitRatio = Math.max(0.2, Math.min(0.8, ratio)); $('browser-primary').style.flex = `${splitRatio} 1 0`; $('browser-secondary').style.flex = `${1 - splitRatio} 1 0`; divider.setAttribute('aria-valuenow', String(Math.round(splitRatio * 100))); scheduleLayout(); }
  divider.addEventListener('pointerdown', (event) => { draggingSplit = true; divider.setPointerCapture(event.pointerId); event.preventDefault(); });
  divider.addEventListener('pointermove', (event) => { if (!draggingSplit) return; const region = $('browser-region').getBoundingClientRect(); setSplitRatio((event.clientX - region.left) / region.width); });
  divider.addEventListener('pointerup', (event) => { draggingSplit = false; if (divider.hasPointerCapture(event.pointerId)) divider.releasePointerCapture(event.pointerId); });
  divider.addEventListener('pointercancel', () => { draggingSplit = false; });
  divider.addEventListener('keydown', (event) => { if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') { event.preventDefault(); setSplitRatio(splitRatio + (event.key === 'ArrowLeft' ? -0.05 : 0.05)); } });
  systemTheme.addEventListener('change', updateTheme);
  window.addEventListener('resize', () => { closeMenu(); closePalette(); scheduleLayout(); });
  document.addEventListener('visibilitychange', () => { updateClock(); if (document.hidden && $('dialog-body').querySelector('.secret-value')) closeDialog(); if (!document.hidden) scheduleLayout(); });
  new ResizeObserver(scheduleLayout).observe($('workspace'));
  render();
})();
