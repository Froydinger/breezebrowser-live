const {
  app,
  BrowserWindow,
  WebContentsView,
  ipcMain,
  Menu,
  nativeTheme,
  session,
  dialog,
  clipboard,
  shell,
} = require('electron');
const path = require('path');
const fs = require('fs');

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let sidebarWidth = 280; // user-resizable, persisted
const ASSISTANT_WIDTH = 360;
const CONTENT_PAD = 10; // breathing room around the page, Arc-style

let win = null;
let blocker = null;
let updateDownloaded = false;

const tabs = new Map(); // id -> { id, view, favicon }
let tabOrder = [];
let activeTabId = null;
let nextTabId = 1;

let sidebarVisible = true;
let sidebarPeek = false; // temporarily shown via edge-hover, not docked
let assistantVisible = false;
let layoutAnim = null;
let currentLeft = sidebarWidth;
let currentRight = 0;

let bookmarks = []; // [{ title, url }]

const NEWTAB_URL = `file://${path.join(__dirname, 'ui', 'newtab.html')}`;
const SETTINGS_URL = `file://${path.join(__dirname, 'ui', 'settings.html')}`;

const ENGINES = {
  google: 'https://www.google.com/search?q=%s',
  duckduckgo: 'https://duckduckgo.com/?q=%s',
  bing: 'https://www.bing.com/search?q=%s',
  brave: 'https://search.brave.com/search?q=%s',
  spectra: 'https://spectranews.us/s/new?q=%s&mode=lightning',
};

const DEFAULT_SETTINGS = {
  theme: 'light',
  accent: '#5b7cfa',
  searchEngine: 'google',
  clock24: false,
  showGreeting: true,
  adblockEnabled: true,
  sidebarVisible: true,
  sidebarWidth: 280,
  permissions: {},
};

let appSettings = { ...DEFAULT_SETTINGS };

function broadcastSettings() {
  if (win) win.webContents.send('settings', appSettings);
  for (const { view } of tabs.values()) {
    if (view.webContents.getURL().startsWith('file://')) {
      view.webContents.send('settings', appSettings);
    }
  }
}

// ---------------------------------------------------------------------------
// Settings (tiny JSON persistence)
// ---------------------------------------------------------------------------

const settingsPath = () => path.join(app.getPath('userData'), 'settings.json');

function loadSettings() {
  try {
    return JSON.parse(fs.readFileSync(settingsPath(), 'utf8'));
  } catch {
    return {};
  }
}

function saveSettings(patch) {
  const next = { ...loadSettings(), ...patch };
  try {
    fs.writeFileSync(settingsPath(), JSON.stringify(next, null, 2));
  } catch {}
  return next;
}

// ---------------------------------------------------------------------------
// Layout (sidebar on the left, assistant on the right, page in the middle)
// ---------------------------------------------------------------------------

function contentBounds(left, right) {
  const [w, h] = win.getContentSize();
  return {
    x: Math.round(left) + CONTENT_PAD,
    y: CONTENT_PAD,
    width: Math.max(0, w - Math.round(left) - Math.round(right) - CONTENT_PAD * 2),
    height: Math.max(0, h - CONTENT_PAD * 2),
  };
}

function applyBounds() {
  if (!win) return;
  const b = contentBounds(currentLeft, currentRight);
  for (const { view } of tabs.values()) view.setBounds(b);
}

function layout() {
  currentLeft = sidebarVisible || sidebarPeek ? sidebarWidth : 0;
  currentRight = assistantVisible ? ASSISTANT_WIDTH : 0;
  applyBounds();
}

function animateLayout() {
  if (layoutAnim) {
    clearInterval(layoutAnim);
    layoutAnim = null;
  }
  const DURATION = 240;
  const fromL = currentLeft;
  const fromR = currentRight;
  const toL = sidebarVisible || sidebarPeek ? sidebarWidth : 0;
  const toR = assistantVisible ? ASSISTANT_WIDTH : 0;
  const start = Date.now();
  const easeOutCubic = (t) => 1 - Math.pow(1 - t, 3);

  layoutAnim = setInterval(() => {
    const t = Math.min(1, (Date.now() - start) / DURATION);
    const k = easeOutCubic(t);
    currentLeft = fromL + (toL - fromL) * k;
    currentRight = fromR + (toR - fromR) * k;
    applyBounds();
    if (t >= 1) {
      clearInterval(layoutAnim);
      layoutAnim = null;
    }
  }, 1000 / 60);
}

function setTrafficLights(show) {
  if (process.platform === 'darwin') {
    try {
      win?.setWindowButtonVisibility(show);
    } catch {}
  }
}

function setSidebar(show) {
  sidebarVisible = show;
  sidebarPeek = false;
  saveSettings({ sidebarVisible: show });
  win?.webContents.send('sidebar', show);
  setTrafficLights(show);
  animateLayout();
}

function peekSidebar() {
  if (sidebarVisible || sidebarPeek) return;
  sidebarPeek = true;
  win?.webContents.send('sidebar-peek', true);
  setTrafficLights(true);
  animateLayout();
}

function endPeek() {
  if (!sidebarPeek) return;
  sidebarPeek = false;
  win?.webContents.send('sidebar-peek', false);
  if (!sidebarVisible) {
    setTrafficLights(false);
    animateLayout();
  }
}

function setAssistant(show) {
  assistantVisible = show;
  win?.webContents.send('assistant', show);
  animateLayout();
  if (show) ensureAI(); // kick off model download/load in the background
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

function tabState(t) {
  const wc = t.view.webContents;
  const url = wc.getURL();
  const isInternal = url.startsWith('file://');
  return {
    id: t.id,
    title: isInternal ? wc.getTitle() || 'New Tab' : wc.getTitle() || 'Loading…',
    url: isInternal ? '' : url,
    favicon: t.favicon || null,
    loading: wc.isLoading(),
    canGoBack: wc.navigationHistory.canGoBack(),
    canGoForward: wc.navigationHistory.canGoForward(),
    pinUrl: t.pinUrl || null,
  };
}

function pushState() {
  if (!win) return;
  win.webContents.send('state', {
    tabs: tabOrder.map((id) => tabState(tabs.get(id))),
    activeTabId,
    bookmarks,
    pins,
  });
}

function createTab(url = NEWTAB_URL, activate = true) {
  const id = nextTabId++;
  const isInternal = url.startsWith('file://');
  const view = new WebContentsView({
    webPreferences: {
      sandbox: true,
      contextIsolation: true,
      preload: path.join(
        __dirname,
        isInternal ? 'internal-preload.js' : 'page-preload.js'
      ),
    },
  });
  const t = { id, view, favicon: null };
  tabs.set(id, t);
  tabOrder.push(id);

  try {
    view.setBorderRadius(12);
  } catch {} // older Electron: no rounded corners, no problem

  const wc = view.webContents;
  const sync = () => pushState();
  wc.on('page-title-updated', sync);
  wc.on('did-start-loading', sync);
  wc.on('did-stop-loading', sync);
  wc.on('did-navigate', sync);
  wc.on('did-navigate-in-page', sync);
  wc.on('page-favicon-updated', (_e, icons) => {
    t.favicon = icons[icons.length - 1] || null;
    pushState();
  });
  // Popups: real windows for auth flows / window.open, tabs for link-opens.
  // Per-tab blocking via right-click on the tab in the sidebar.
  wc.setWindowOpenHandler((details) => {
    if (popupsBlocked.has(id)) return { action: 'deny' };
    if (
      details.disposition === 'foreground-tab' ||
      details.disposition === 'background-tab'
    ) {
      createTab(details.url, details.disposition === 'foreground-tab');
      return { action: 'deny' };
    }
    return {
      action: 'allow',
      overrideBrowserWindowOptions: {
        autoHideMenuBar: true,
        width: 560,
        height: 720,
        backgroundColor:
          nativeTheme.themeSource === 'dark' ? '#16161a' : '#ffffff',
      },
    };
  });
  wc.on('enter-html-full-screen', () => {
    const [width, height] = win.getContentSize();
    view.setBounds({ x: 0, y: 0, width, height });
  });
  wc.on('leave-html-full-screen', applyBounds);
  wc.on('did-navigate', (_e, navUrl) => recordHistory(wc, navUrl));
  wc.on('did-navigate-in-page', (_e, navUrl, isMain) => {
    if (isMain) recordHistory(wc, navUrl);
  });
  wc.on('context-menu', (_e, p) => showPageContextMenu(wc, p));

  wc.loadURL(url);
  if (activate) activateTab(id);
  else pushState();
  return id;
}

function activateTab(id) {
  const t = tabs.get(id);
  if (!t || !win) return;
  if (activeTabId && tabs.has(activeTabId)) {
    win.contentView.removeChildView(tabs.get(activeTabId).view);
  }
  activeTabId = id;
  win.contentView.addChildView(t.view);
  applyBounds();
  t.view.webContents.focus();
  pushState();
}

function closeTab(id) {
  const t = tabs.get(id);
  if (!t) return;
  const idx = tabOrder.indexOf(id);
  tabOrder = tabOrder.filter((x) => x !== id);
  if (activeTabId === id) {
    win.contentView.removeChildView(t.view);
    activeTabId = null;
    const next = tabOrder[Math.min(idx, tabOrder.length - 1)];
    if (next) activateTab(next);
  }
  t.view.webContents.close();
  tabs.delete(id);
  if (tabOrder.length === 0) createTab();
  pushState();
}

function cycleTab(dir) {
  if (tabOrder.length < 2) return;
  const idx = tabOrder.indexOf(activeTabId);
  const next = tabOrder[(idx + dir + tabOrder.length) % tabOrder.length];
  activateTab(next);
}

function activeWC() {
  const t = tabs.get(activeTabId);
  return t ? t.view.webContents : null;
}

function toNavigableURL(input) {
  const q = input.trim();
  if (!q) return null;
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(q)) return q;
  if (q === 'localhost' || q.startsWith('localhost:')) return `http://${q}`;
  if (/^[^\s]+\.[^\s]{2,}(\/.*)?$/.test(q) && !q.includes(' ')) return `https://${q}`;
  const engine = ENGINES[appSettings.searchEngine] || ENGINES.google;
  return engine.replace('%s', encodeURIComponent(q));
}

function openInternalTab(url) {
  for (const id of tabOrder) {
    if (tabs.get(id).view.webContents.getURL() === url) {
      activateTab(id);
      return;
    }
  }
  createTab(url, true);
}

const openSettingsTab = () => openInternalTab(SETTINGS_URL);

// ---------------------------------------------------------------------------
// Bookmarks
// ---------------------------------------------------------------------------

const BOOKMARKS_URL = `file://${path.join(__dirname, 'ui', 'bookmarks.html')}`;

function broadcastBookmarks() {
  for (const { view } of tabs.values()) {
    if (view.webContents.getURL().startsWith('file://')) {
      view.webContents.send('bookmarks', bookmarks);
    }
  }
}

function toggleBookmark() {
  const wc = activeWC();
  if (!wc) return;
  const url = wc.getURL();
  if (!url || url.startsWith('file://')) return;
  const idx = bookmarks.findIndex((b) => b.url === url);
  if (idx >= 0) bookmarks.splice(idx, 1);
  else bookmarks.push({ title: wc.getTitle() || url, url });
  saveSettings({ bookmarks });
  pushState();
  broadcastBookmarks();
}

// ---------------------------------------------------------------------------
// Pinned tabs (square app launchers above the tab list; survive tab close)
// ---------------------------------------------------------------------------

let pins = []; // [{ title, url, favicon }]
const popupsBlocked = new Set(); // tab ids with popups disabled

function pinTab(id) {
  const t = tabs.get(id);
  if (!t) return;
  const url = t.view.webContents.getURL();
  if (!url || url.startsWith('file://')) return;
  if (pins.some((p) => p.url === url)) return;
  pins.push({ title: t.view.webContents.getTitle() || url, url, favicon: t.favicon });
  t.pinUrl = url; // the tab now lives inside the pin, not the tab list
  saveSettings({ pins });
  pushState();
}

function unpin(url) {
  pins = pins.filter((p) => p.url !== url);
  for (const t of tabs.values()) {
    if (t.pinUrl === url) t.pinUrl = null; // back to the regular tab list
  }
  saveSettings({ pins });
  pushState();
}

function pinnedTab(url) {
  for (const id of tabOrder) {
    const t = tabs.get(id);
    if (t.pinUrl === url || t.view.webContents.getURL() === url) return t;
  }
  return null;
}

function openPin(url) {
  const t = pinnedTab(url);
  if (t) {
    t.pinUrl = url;
    activateTab(t.id);
    return;
  }
  const id = createTab(url, true);
  const created = tabs.get(id);
  if (created) created.pinUrl = url;
  pushState();
}

function closePin(url) {
  const t = pinnedTab(url);
  if (t) closeTab(t.id); // closeTab lands on a neighbor or a fresh new tab
}

// ---------------------------------------------------------------------------
// Context menus (sidebar tabs + web pages)
// ---------------------------------------------------------------------------

function showTabContextMenu(id) {
  const t = tabs.get(id);
  if (!t) return;
  const url = t.view.webContents.getURL();
  const isPinned = pins.some((p) => p.url === url);
  const isWeb = url && !url.startsWith('file://');
  Menu.buildFromTemplate([
    {
      label: isPinned ? 'Unpin' : 'Pin Tab',
      enabled: isWeb,
      click: () => (isPinned ? unpin(url) : pinTab(id)),
    },
    {
      label: 'Duplicate Tab',
      enabled: isWeb,
      click: () => createTab(url, true),
    },
    { type: 'separator' },
    {
      label: 'Allow Popups',
      type: 'checkbox',
      checked: !popupsBlocked.has(id),
      click: () => {
        if (popupsBlocked.has(id)) popupsBlocked.delete(id);
        else popupsBlocked.add(id);
      },
    },
    { type: 'separator' },
    { label: 'Close Tab', click: () => closeTab(id) },
  ]).popup({ window: win });
}

function showPageContextMenu(wc, p) {
  const items = [];
  if (p.linkURL) {
    items.push(
      { label: 'Open Link in New Tab', click: () => createTab(p.linkURL, true) },
      {
        label: 'Open Link in Background',
        click: () => createTab(p.linkURL, false),
      },
      { label: 'Copy Link', click: () => clipboard.writeText(p.linkURL) },
      { type: 'separator' }
    );
  }
  if (p.mediaType === 'image' && p.srcURL) {
    items.push(
      { label: 'Copy Image', click: () => wc.copyImageAt(p.x, p.y) },
      { label: 'Save Image…', click: () => wc.downloadURL(p.srcURL) },
      {
        label: 'Open Image in New Tab',
        click: () => createTab(p.srcURL, true),
      },
      { type: 'separator' }
    );
  }
  const sel = (p.selectionText || '').trim();
  if (sel) {
    const short = sel.length > 30 ? sel.slice(0, 30) + '…' : sel;
    const engine = ENGINES[appSettings.searchEngine] || ENGINES.google;
    items.push(
      {
        label: `Search for “${short}”`,
        click: () => createTab(engine.replace('%s', encodeURIComponent(sel)), true),
      },
      { role: 'copy' },
      { type: 'separator' }
    );
  }
  if (p.isEditable) {
    items.push(
      { role: 'undo' },
      { role: 'redo' },
      { type: 'separator' },
      { role: 'cut' },
      { role: 'copy' },
      { role: 'paste' },
      { role: 'selectAll' },
      { type: 'separator' }
    );
  }
  items.push(
    {
      label: 'Back',
      enabled: wc.navigationHistory.canGoBack(),
      click: () => wc.navigationHistory.goBack(),
    },
    {
      label: 'Forward',
      enabled: wc.navigationHistory.canGoForward(),
      click: () => wc.navigationHistory.goForward(),
    },
    { label: 'Reload', click: () => wc.reload() },
    { type: 'separator' },
    {
      label: 'Bookmark This Page',
      click: () => toggleBookmark(),
    },
    { type: 'separator' },
    {
      label: 'Inspect Element',
      click: () => {
        wc.inspectElement(p.x, p.y);
      },
    }
  );
  Menu.buildFromTemplate(items).popup({ window: win });
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

const HISTORY_URL = `file://${path.join(__dirname, 'ui', 'history.html')}`;
const historyPath = () => path.join(app.getPath('userData'), 'history.json');
let history = [];
let historySaveTimer = null;

function loadHistory() {
  try {
    history = JSON.parse(fs.readFileSync(historyPath(), 'utf8'));
  } catch {
    history = [];
  }
}

function saveHistorySoon() {
  clearTimeout(historySaveTimer);
  historySaveTimer = setTimeout(() => {
    try {
      fs.writeFileSync(historyPath(), JSON.stringify(history));
    } catch {}
  }, 1500);
}

function recordHistory(wc, url) {
  if (!/^https?:\/\//.test(url)) return;
  const last = history[0];
  if (last && last.url === url && Date.now() - last.ts < 5000) return;
  history.unshift({ url, title: wc.getTitle() || url, ts: Date.now() });
  if (history.length > 5000) history.length = 5000;
  saveHistorySoon();
  // backfill the title once the page reports it
  wc.once('page-title-updated', (_e, title) => {
    const entry = history.find((h) => h.url === url);
    if (entry && title) {
      entry.title = title;
      saveHistorySoon();
    }
  });
}

// ---------------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------------

const DOWNLOADS_URL = `file://${path.join(__dirname, 'ui', 'downloads.html')}`;
const downloadsPath = () => path.join(app.getPath('userData'), 'downloads.json');
const downloadItems = new Map(); // id -> DownloadItem (live only)
let downloadList = []; // [{ id, filename, path, url, totalBytes, receivedBytes, state, ts }]
let downloadSeq = 1;

function loadDownloads() {
  try {
    downloadList = JSON.parse(fs.readFileSync(downloadsPath(), 'utf8'));
    downloadSeq = Math.max(0, ...downloadList.map((d) => d.id)) + 1;
  } catch {
    downloadList = [];
  }
}

function saveDownloads() {
  try {
    fs.writeFileSync(
      downloadsPath(),
      JSON.stringify(downloadList.filter((d) => d.state !== 'progressing').slice(0, 200))
    );
  } catch {}
}

function broadcastDownloads() {
  if (win) win.webContents.send('downloads', downloadList);
  for (const { view } of tabs.values()) {
    if (view.webContents.getURL().startsWith('file://')) {
      view.webContents.send('downloads', downloadList);
    }
  }
}

function uniqueSavePath(filename) {
  const dir = app.getPath('downloads');
  const ext = path.extname(filename);
  const base = path.basename(filename, ext);
  let candidate = path.join(dir, filename);
  for (let i = 1; fs.existsSync(candidate); i++) {
    candidate = path.join(dir, `${base} (${i})${ext}`);
  }
  return candidate;
}

function setupDownloads() {
  session.defaultSession.on('will-download', (_e, item) => {
    const id = downloadSeq++;
    const savePath = uniqueSavePath(item.getFilename());
    item.setSavePath(savePath);
    const entry = {
      id,
      filename: path.basename(savePath),
      path: savePath,
      url: item.getURL(),
      totalBytes: item.getTotalBytes(),
      receivedBytes: 0,
      state: 'progressing',
      ts: Date.now(),
    };
    downloadList.unshift(entry);
    downloadItems.set(id, item);

    item.on('updated', (_ev, state) => {
      entry.receivedBytes = item.getReceivedBytes();
      entry.totalBytes = item.getTotalBytes();
      entry.state = state === 'interrupted' ? 'interrupted' : 'progressing';
      broadcastDownloads();
    });
    item.once('done', (_ev, state) => {
      entry.receivedBytes = item.getReceivedBytes();
      entry.state = state; // 'completed' | 'cancelled' | 'interrupted'
      downloadItems.delete(id);
      saveDownloads();
      broadcastDownloads();
    });
    broadcastDownloads();
  });
}

// ---------------------------------------------------------------------------
// Speed: connection pre-warming + omnibox suggestions
// ---------------------------------------------------------------------------

const SUGGEST = {
  google: 'https://suggestqueries.google.com/complete/search?client=firefox&q=%s',
  bing: 'https://api.bing.com/osjson.aspx?query=%s',
  duckduckgo: 'https://duckduckgo.com/ac/?q=%s&type=list',
  brave: 'https://search.brave.com/api/suggest?q=%s',
};

const preconnected = new Map(); // origin -> last warm-up ts

function preconnect(url) {
  try {
    const origin = new URL(url).origin;
    if (Date.now() - (preconnected.get(origin) || 0) < 30000) return;
    preconnected.set(origin, Date.now());
    session.defaultSession.preconnect({ url: origin, numSockets: 1 });
  } catch {}
}

ipcMain.on('link-hover', (_e, url) => preconnect(url));

// warm the search engine + most-visited origins right after launch
function warmConnections() {
  const origins = new Set();
  try {
    origins.add(new URL(ENGINES[appSettings.searchEngine] || ENGINES.google).origin);
  } catch {}
  for (const h of history.slice(0, 80)) {
    if (origins.size >= 6) break;
    try {
      origins.add(new URL(h.url).origin);
    } catch {}
  }
  for (const o of origins) preconnect(o);
}

ipcMain.handle('get-suggestions', async (_e, q) => {
  const query = String(q || '').trim();
  if (!query) return { history: [], bookmarks: [], web: [] };
  const lower = query.toLowerCase();

  const seen = new Set();
  const hist = [];
  for (const h of history) {
    if (hist.length >= 4) break;
    if (seen.has(h.url)) continue;
    if (
      h.url.toLowerCase().includes(lower) ||
      (h.title || '').toLowerCase().includes(lower)
    ) {
      seen.add(h.url);
      hist.push({ title: h.title, url: h.url });
    }
  }

  const bms = bookmarks
    .filter(
      (b) =>
        b.url.toLowerCase().includes(lower) ||
        b.title.toLowerCase().includes(lower)
    )
    .slice(0, 3);

  let web = [];
  try {
    const tmpl = SUGGEST[appSettings.searchEngine] || SUGGEST.google;
    const ctrl = new AbortController();
    const to = setTimeout(() => ctrl.abort(), 700);
    const res = await fetch(tmpl.replace('%s', encodeURIComponent(query)), {
      signal: ctrl.signal,
    });
    clearTimeout(to);
    const data = await res.json();
    if (Array.isArray(data) && Array.isArray(data[1])) {
      web = data[1].slice(0, 4).map(String);
    } else if (Array.isArray(data)) {
      web = data
        .filter((x) => x && x.phrase)
        .map((x) => x.phrase)
        .slice(0, 4);
    }
  } catch {} // offline or slow suggest endpoint — local results still show

  // pre-warm the most likely destination while the user is still typing
  if (hist[0]) preconnect(hist[0].url);

  return { history: hist, bookmarks: bms, web };
});

// ---------------------------------------------------------------------------
// Permission prompts (per-origin, remembered)
// ---------------------------------------------------------------------------

const PERM_LABELS = {
  media: 'use your camera and/or microphone',
  geolocation: 'know your location',
  notifications: 'send you notifications',
  'clipboard-read': 'read your clipboard',
  midi: 'use MIDI devices',
};

function setupPermissions() {
  const ses = session.defaultSession;
  const autoAllow = new Set([
    'fullscreen',
    'clipboard-sanitized-write',
    'pointerLock',
    'keyboardLock',
    'window-management',
    'publickey-credentials-get', // WebAuthn / passkeys
    'publickey-credentials-create',
  ]);
  // synchronous probes (e.g. WebAuthn availability checks)
  ses.setPermissionCheckHandler((_wc, permission, origin) => {
    if (autoAllow.has(permission)) return true;
    const saved = (appSettings.permissions || {})[origin]?.[permission];
    return saved === true;
  });
  ses.setPermissionRequestHandler(async (wc, permission, callback, details) => {
    if (autoAllow.has(permission)) return callback(true);
    if (!PERM_LABELS[permission]) return callback(false);
    let origin;
    try {
      origin = new URL(details.requestingUrl || wc.getURL()).origin;
    } catch {
      return callback(false);
    }
    const saved = (appSettings.permissions || {})[origin]?.[permission];
    if (saved !== undefined) return callback(saved);
    const { response } = await dialog.showMessageBox(win, {
      type: 'question',
      message: `Allow ${origin.replace(/^https?:\/\//, '')} to ${PERM_LABELS[permission]}?`,
      buttons: ['Allow', 'Block'],
      defaultId: 0,
      cancelId: 1,
    });
    const allow = response === 0;
    const perms = appSettings.permissions || {};
    perms[origin] = { ...perms[origin], [permission]: allow };
    applySetting('permissions', perms);
    callback(allow);
  });
}

// ---------------------------------------------------------------------------
// Ad blocking
// ---------------------------------------------------------------------------

async function setupAdblock() {
  try {
    const { ElectronBlocker } = require('@ghostery/adblocker-electron');
    blocker = await ElectronBlocker.fromPrebuiltAdsAndTracking(fetch, {
      path: path.join(app.getPath('userData'), 'adblock-engine.bin'),
      read: fs.promises.readFile,
      write: fs.promises.writeFile,
    });
    if (appSettings.adblockEnabled) {
      blocker.enableBlockingInSession(session.defaultSession);
    }
    let blocked = 0;
    blocker.on('request-blocked', () => {
      blocked++;
      if (win && blocked % 5 === 1) win.webContents.send('adblock-count', blocked);
    });
  } catch (err) {
    console.error('Adblock failed to initialize:', err.message);
  }
}

// ---------------------------------------------------------------------------
// Local AI assistant (llama.cpp via node-llama-cpp, Metal-accelerated)
// ---------------------------------------------------------------------------

const MODEL_URI =
  'hf:bartowski/Llama-3.2-3B-Instruct-GGUF/Llama-3.2-3B-Instruct-Q4_K_M.gguf';

const ai = {
  ready: false,
  loading: false,
  generating: false,
  session: null,
  context: null,
  sequence: null,
  LlamaChatSession: null,
  abort: null,
  lastCtxUrl: null,
};

function sendAI(status) {
  win?.webContents.send('ai-status', status);
}

async function ensureAI() {
  if (ai.ready || ai.loading) return ai.ready;
  ai.loading = true;
  try {
    const { getLlama, LlamaChatSession, resolveModelFile } = await import(
      'node-llama-cpp'
    );
    ai.LlamaChatSession = LlamaChatSession;

    sendAI({ state: 'downloading', progress: 0 });
    const modelPath = await resolveModelFile(MODEL_URI, {
      directory: path.join(app.getPath('userData'), 'models'),
      onProgress: ({ downloadedSize, totalSize }) =>
        sendAI({
          state: 'downloading',
          progress: totalSize ? downloadedSize / totalSize : 0,
        }),
    });

    sendAI({ state: 'loading' });
    const llama = await getLlama();
    const model = await llama.loadModel({ modelPath });
    ai.context = await model.createContext({ contextSize: { max: 8192 } });
    newChat();
    ai.ready = true;
    sendAI({ state: 'ready' });
  } catch (err) {
    console.error('AI init failed:', err);
    sendAI({ state: 'error', message: err.message });
  }
  ai.loading = false;
  return ai.ready;
}

function newChat() {
  try {
    ai.session?.dispose();
    ai.sequence?.dispose();
  } catch {}
  ai.sequence = ai.context.getSequence();
  ai.session = new ai.LlamaChatSession({
    contextSequence: ai.sequence,
    systemPrompt:
      'You are Breeze, a helpful assistant built into a web browser. ' +
      'Answer concisely. When page content is provided, ground your answers in it.',
  });
  ai.lastCtxUrl = null;
}

async function getPageContext() {
  const wc = activeWC();
  if (!wc) return null;
  const url = wc.getURL();
  if (!url || url.startsWith('file://')) return null;
  try {
    const text = await wc.executeJavaScript(
      'document.body ? document.body.innerText : ""',
      true
    );
    return { title: wc.getTitle(), url, text: String(text).slice(0, 6000) };
  } catch {
    return null;
  }
}

ipcMain.on('ai-ask', async (_e, { text, includePage }) => {
  if (ai.generating) return;
  if (!(await ensureAI())) return;
  ai.generating = true;
  sendAI({ state: 'generating' });

  let prompt = text;
  if (includePage) {
    const ctx = await getPageContext();
    if (ctx && ctx.url !== ai.lastCtxUrl) {
      prompt =
        `[Current page: "${ctx.title}" — ${ctx.url}]\n` +
        `[Page content]\n${ctx.text}\n[End page content]\n\n${text}`;
      ai.lastCtxUrl = ctx.url;
    }
  }

  ai.abort = new AbortController();
  try {
    await ai.session.prompt(prompt, {
      signal: ai.abort.signal,
      onTextChunk: (chunk) => win?.webContents.send('ai-chunk', chunk),
    });
  } catch (err) {
    if (!ai.abort.signal.aborted) {
      sendAI({ state: 'error', message: err.message });
    }
  }
  ai.generating = false;
  win?.webContents.send('ai-done');
  sendAI({ state: 'ready' });
});

ipcMain.on('ai-stop', () => ai.abort?.abort());
ipcMain.on('ai-new-chat', () => {
  if (ai.ready && !ai.generating) {
    newChat();
    win?.webContents.send('ai-cleared');
  }
});

// ---------------------------------------------------------------------------
// Auto update
// ---------------------------------------------------------------------------

function setupAutoUpdate() {
  if (!app.isPackaged) return; // dev mode: skip
  try {
    const { autoUpdater } = require('electron-updater');
    autoUpdater.autoDownload = true;
    autoUpdater.on('update-downloaded', () => {
      updateDownloaded = true;
      if (win) win.webContents.send('update-ready');
    });
    autoUpdater.checkForUpdatesAndNotify().catch(() => {});
    // re-check every 4 hours while running
    setInterval(() => autoUpdater.checkForUpdates().catch(() => {}), 4 * 60 * 60 * 1000);
  } catch (err) {
    console.error('Auto-update unavailable:', err.message);
  }
}

// ---------------------------------------------------------------------------
// Window + menu
// ---------------------------------------------------------------------------

function applyTheme(theme) {
  nativeTheme.themeSource = theme;
  if (win) {
    win.setBackgroundColor(theme === 'dark' ? '#16161a' : '#f2f0ed');
    win.webContents.send('theme', theme);
  }
  // internal pages (new tab, settings) follow instantly via their preload
  for (const { view } of tabs.values()) {
    if (view.webContents.getURL().startsWith('file://')) {
      view.webContents.send('theme', theme);
    }
  }
}

function applySetting(key, value) {
  appSettings[key] = value;
  saveSettings({ [key]: value });
  if (key === 'theme') applyTheme(value);
  if (key === 'adblockEnabled' && blocker) {
    if (value) blocker.enableBlockingInSession(session.defaultSession);
    else blocker.disableBlockingInSession(session.defaultSession);
  }
  broadcastSettings();
}

function createWindow() {
  const settings = loadSettings();
  appSettings = { ...DEFAULT_SETTINGS, ...settings };
  sidebarVisible = appSettings.sidebarVisible !== false;
  bookmarks = Array.isArray(settings.bookmarks) ? settings.bookmarks : [];
  pins = Array.isArray(settings.pins) ? settings.pins : [];
  sidebarWidth = Math.min(420, Math.max(220, appSettings.sidebarWidth || 280));
  const theme = appSettings.theme;
  nativeTheme.themeSource = theme;

  win = new BrowserWindow({
    width: 1280,
    height: 832,
    minWidth: 600,
    minHeight: 400,
    title: 'Breeze',
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'hidden',
    trafficLightPosition: { x: 18, y: 20 },
    backgroundColor: theme === 'dark' ? '#16161a' : '#f2f0ed',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
    },
  });

  win.loadFile(path.join(__dirname, 'ui', 'index.html'));
  if (process.platform === 'darwin' && !sidebarVisible) {
    try {
      win.setWindowButtonVisibility(false);
    } catch {}
  }
  win.on('resize', applyBounds);
  win.on('closed', () => {
    win = null;
  });

  win.webContents.once('did-finish-load', () => {
    win.webContents.send('theme', theme);
    win.webContents.send('sidebar', sidebarVisible);
    win.webContents.send('settings', appSettings);
    layout();
    createTab();
  });
}

function buildMenu() {
  const isMac = process.platform === 'darwin';
  const template = [
    ...(isMac ? [{ role: 'appMenu' }] : []),
    {
      label: 'File',
      submenu: [
        {
          label: 'Settings…',
          accelerator: 'CmdOrCtrl+,',
          click: () => openSettingsTab(),
        },
        { type: 'separator' },
        {
          label: 'New Tab',
          accelerator: 'CmdOrCtrl+T',
          click: () => {
            createTab();
            win?.webContents.send('focus-address');
          },
        },
        {
          label: 'Close Tab',
          accelerator: 'CmdOrCtrl+W',
          click: () => closeTab(activeTabId),
        },
        { type: 'separator' },
        isMac ? { role: 'close' } : { role: 'quit' },
      ],
    },
    { role: 'editMenu' },
    {
      label: 'View',
      submenu: [
        {
          label: 'Toggle Sidebar',
          accelerator: 'CmdOrCtrl+S',
          click: () => setSidebar(!sidebarVisible),
        },
        {
          label: 'Toggle Assistant',
          accelerator: 'CmdOrCtrl+E',
          click: () => setAssistant(!assistantVisible),
        },
        {
          label: 'Focus Address Bar',
          accelerator: 'CmdOrCtrl+L',
          click: () => {
            if (!sidebarVisible) setSidebar(true);
            win?.webContents.send('focus-address');
          },
        },
        {
          label: 'Bookmark This Page',
          accelerator: 'CmdOrCtrl+D',
          click: () => toggleBookmark(),
        },
        {
          label: 'Toggle Dark Mode',
          accelerator: 'CmdOrCtrl+Shift+D',
          click: () => {
            const next = nativeTheme.themeSource === 'dark' ? 'light' : 'dark';
            saveSettings({ theme: next });
            applyTheme(next);
          },
        },
        { type: 'separator' },
        {
          label: 'Reload Page',
          accelerator: 'CmdOrCtrl+R',
          click: () => activeWC()?.reload(),
        },
        {
          label: 'Hard Reload',
          accelerator: 'CmdOrCtrl+Shift+R',
          click: () => activeWC()?.reloadIgnoringCache(),
        },
        { type: 'separator' },
        {
          label: 'Actual Size',
          accelerator: 'CmdOrCtrl+0',
          click: () => activeWC()?.setZoomLevel(0),
        },
        {
          label: 'Zoom In',
          accelerator: 'CmdOrCtrl+Plus',
          click: () => {
            const wc = activeWC();
            if (wc) wc.setZoomLevel(wc.getZoomLevel() + 0.5);
          },
        },
        {
          label: 'Zoom Out',
          accelerator: 'CmdOrCtrl+-',
          click: () => {
            const wc = activeWC();
            if (wc) wc.setZoomLevel(wc.getZoomLevel() - 0.5);
          },
        },
        { type: 'separator' },
        { role: 'togglefullscreen' },
        {
          label: 'Developer Tools',
          accelerator: isMac ? 'Alt+Cmd+I' : 'Ctrl+Shift+I',
          click: () => activeWC()?.openDevTools({ mode: 'detach' }),
        },
      ],
    },
    {
      label: 'History',
      submenu: [
        {
          label: 'Back',
          accelerator: 'CmdOrCtrl+[',
          click: () => activeWC()?.navigationHistory.goBack(),
        },
        {
          label: 'Forward',
          accelerator: 'CmdOrCtrl+]',
          click: () => activeWC()?.navigationHistory.goForward(),
        },
        { type: 'separator' },
        {
          label: 'Show Bookmarks',
          accelerator: 'CmdOrCtrl+Alt+B',
          click: () => openInternalTab(BOOKMARKS_URL),
        },
        {
          label: 'Show History',
          accelerator: 'CmdOrCtrl+Y',
          click: () => openInternalTab(HISTORY_URL),
        },
        {
          label: 'Show Downloads',
          accelerator: 'CmdOrCtrl+Shift+J',
          click: () => openInternalTab(DOWNLOADS_URL),
        },
      ],
    },
    {
      label: 'Tab',
      submenu: [
        {
          label: 'Next Tab',
          accelerator: 'Ctrl+Tab',
          click: () => cycleTab(1),
        },
        {
          label: 'Previous Tab',
          accelerator: 'Ctrl+Shift+Tab',
          click: () => cycleTab(-1),
        },
        ...Array.from({ length: 9 }, (_, i) => ({
          label: `Tab ${i + 1}`,
          accelerator: `CmdOrCtrl+${i + 1}`,
          click: () => {
            const id = i === 8 ? tabOrder[tabOrder.length - 1] : tabOrder[i];
            if (id) activateTab(id);
          },
        })),
      ],
    },
    { role: 'windowMenu' },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// ---------------------------------------------------------------------------
// IPC
// ---------------------------------------------------------------------------

ipcMain.on('new-tab', () => createTab());
ipcMain.on('close-tab', (_e, id) => closeTab(id));
ipcMain.on('activate-tab', (_e, id) => activateTab(id));
ipcMain.on('navigate', (_e, input) => {
  const url = toNavigableURL(input);
  if (url) activeWC()?.loadURL(url);
});
ipcMain.on('open-url', (_e, url) => activeWC()?.loadURL(url));
ipcMain.on('open-url-new-tab', (_e, url) => createTab(url, true));
ipcMain.on('go-back', () => activeWC()?.navigationHistory.goBack());
ipcMain.on('go-forward', () => activeWC()?.navigationHistory.goForward());
ipcMain.on('reload', () => activeWC()?.reload());
ipcMain.on('toggle-sidebar', () => setSidebar(!sidebarVisible));
ipcMain.on('toggle-assistant', () => setAssistant(!assistantVisible));
ipcMain.on('toggle-bookmark', () => toggleBookmark());
ipcMain.on('remove-bookmark', (_e, url) => {
  bookmarks = bookmarks.filter((b) => b.url !== url);
  saveSettings({ bookmarks });
  pushState();
  broadcastBookmarks();
});
ipcMain.handle('get-bookmarks', () => bookmarks);
ipcMain.on('open-bookmarks', () => openInternalTab(BOOKMARKS_URL));
ipcMain.on('pin-tab', (_e, id) => pinTab(id));
ipcMain.on('set-theme', (_e, theme) => {
  saveSettings({ theme });
  applyTheme(theme);
});
ipcMain.on('install-update', () => {
  if (!updateDownloaded) return;
  const { autoUpdater } = require('electron-updater');
  autoUpdater.quitAndInstall();
});
ipcMain.handle('get-init', () => ({
  theme: nativeTheme.themeSource === 'dark' ? 'dark' : 'light',
  sidebarVisible,
  settings: appSettings,
}));
ipcMain.handle('get-settings', () => appSettings);
ipcMain.on('set-sidebar-width', (_e, w) => {
  sidebarWidth = Math.min(420, Math.max(220, Math.round(w)));
  if (sidebarVisible) {
    currentLeft = sidebarWidth;
    applyBounds();
  }
});
ipcMain.on('save-sidebar-width', () => applySetting('sidebarWidth', sidebarWidth));
ipcMain.on('tab-context-menu', (_e, id) => showTabContextMenu(id));
ipcMain.on('open-pin', (_e, url) => openPin(url));
ipcMain.on('pin-context-menu', (_e, url) => {
  const open = !!pinnedTab(url);
  Menu.buildFromTemplate([
    { label: 'Open', click: () => openPin(url) },
    {
      label: 'Close',
      enabled: open,
      click: () => closePin(url), // closes the tab, keeps the pin
    },
    { type: 'separator' },
    { label: 'Unpin', click: () => unpin(url) },
  ]).popup({ window: win });
});
ipcMain.on('peek-sidebar', () => peekSidebar());
ipcMain.on('end-peek', () => endPeek());
ipcMain.on('open-downloads', () => openInternalTab(DOWNLOADS_URL));
ipcMain.on('open-history', () => openInternalTab(HISTORY_URL));
ipcMain.handle('get-history', () => history.slice(0, 2000));
ipcMain.on('clear-history', () => {
  history = [];
  saveHistorySoon();
});
ipcMain.on('delete-history-item', (_e, { url, ts }) => {
  history = history.filter((h) => !(h.url === url && h.ts === ts));
  saveHistorySoon();
});
ipcMain.handle('get-downloads', () => downloadList);
ipcMain.on('download-cancel', (_e, id) => downloadItems.get(id)?.cancel());
ipcMain.on('download-open', (_e, id) => {
  const d = downloadList.find((x) => x.id === id);
  if (d?.path) shell.openPath(d.path);
});
ipcMain.on('download-show', (_e, id) => {
  const d = downloadList.find((x) => x.id === id);
  if (d?.path) shell.showItemInFolder(d.path);
});
ipcMain.on('downloads-clear', () => {
  downloadList = downloadList.filter((d) => d.state === 'progressing');
  saveDownloads();
  broadcastDownloads();
});
ipcMain.on('set-setting', (_e, { key, value }) => {
  if (key in DEFAULT_SETTINGS) applySetting(key, value);
});
ipcMain.on('open-settings', () => openSettingsTab());

// ---------------------------------------------------------------------------
// App lifecycle
// ---------------------------------------------------------------------------

app.whenReady().then(async () => {
  appSettings = { ...DEFAULT_SETTINGS, ...loadSettings() };
  loadHistory();
  loadDownloads();
  setupDownloads();
  setupPermissions();
  await setupAdblock();
  buildMenu();
  createWindow();
  setupAutoUpdate();
  warmConnections();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
