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
  Notification,
} = require('electron');
const path = require('path');
const fs = require('fs');

// Media can start without a user gesture (fixes YouTube needing a refresh
// before the video plays on first load).
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');

// Sites sniff the UA; any non-standard token (Electron/x, Breeze/x) makes
// Google & co. serve degraded or broken layouts. Strip everything but the
// standard Chrome/Safari tokens so we look like plain Chrome.
app.userAgentFallback = app.userAgentFallback
  .replace(/\sElectron\/\S+/i, '')
  .replace(/\sBreeze\/\S+/i, '')
  .replace(/\sbreeze-browser\/\S+/i, '')
  .replace(/\s{2,}/g, ' ')
  .trim();

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
  urlBarPosition: 'top', // 'top' | 'sidebar'
  autoPip: true,
  pinSize: 'large', // 'small' | 'medium' | 'large'
  neverSavePasswords: [], // origins the user declined to save for
  userName: '', // given to the AI
  aiInstructions: '', // standing custom instructions for the AI
  openaiKey: '', // optional, for image generation
  onboarded: false, // first-run setup dialog shown
  webNotifications: true, // sites may show notifications (browser-wide)
  tabSleepHours: 4, // 2 | 4 | 6 | 0 (never)
  pinSize: 'large', // 'small' | 'medium' | 'large'
  neverSavePasswords: [], // origins the user said "never" for
  permissions: {},
};

const TOPBAR_HEIGHT = 48; // reserved above the page when the URL bar is on top
let omniboxOffset = 0; // extra top push while the omnibox dropdown is open

let appSettings = { ...DEFAULT_SETTINGS };

function broadcastSettings() {
  if (win) win.webContents.send('settings', appSettings);
  for (const { view } of tabs.values()) {
    if (view && view.webContents.getURL().startsWith('file://')) {
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
  const top =
    (appSettings.urlBarPosition === 'top' ? TOPBAR_HEIGHT : 0) + omniboxOffset;
  return {
    x: Math.round(left) + CONTENT_PAD,
    y: CONTENT_PAD + top,
    width: Math.max(0, w - Math.round(left) - Math.round(right) - CONTENT_PAD * 2),
    height: Math.max(0, h - CONTENT_PAD * 2 - top),
  };
}

function applyBounds() {
  if (!win) return;
  const b = contentBounds(currentLeft, currentRight);
  for (const { view } of tabs.values()) if (view) view.setBounds(b);
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
  if (show) stopEdgePoll();
  else startEdgePoll(); // only poll the cursor while the sidebar is hidden
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

// Edge-hover detection via cursor polling: the DOM strip only covers the
// 10px chrome ring, so poll the real cursor for a generous hit zone that
// works across the whole left edge. Only runs WHILE the sidebar is hidden —
// otherwise a constant timer keeps the CPU awake (fans/battery).
const { screen } = require('electron');
let edgePoll = null;

function startEdgePoll() {
  if (edgePoll) return;
  edgePoll = setInterval(() => {
    if (!win || sidebarVisible || win.isDestroyed() || !win.isFocused()) return;
    try {
      const cur = screen.getCursorScreenPoint();
      const b = win.getBounds();
      const insideY = cur.y >= b.y && cur.y <= b.y + b.height;
      if (!sidebarPeek) {
        if (insideY && cur.x >= b.x && cur.x <= b.x + 12) peekSidebar();
      } else {
        const out =
          !insideY || cur.x < b.x - 40 || cur.x > b.x + sidebarWidth + 60;
        if (out) endPeek();
      }
    } catch {}
  }, 200);
}

function stopEdgePoll() {
  if (edgePoll) {
    clearInterval(edgePoll);
    edgePoll = null;
  }
}

function setAssistant(show) {
  assistantVisible = show;
  win?.webContents.send('assistant', show);
  animateLayout();
  if (show) {
    clearTimeout(ai.idleTimer);
    ensureAI(); // kick off model download/load in the background
  } else {
    scheduleAIIdleUnload(); // free the model after the panel's been closed a while
  }
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

function tabURL(t) {
  if (t.sleeping) return t.saved?.url || '';
  return t.view ? t.view.webContents.getURL() : '';
}

function tabState(t) {
  if (t.sleeping) {
    return {
      id: t.id,
      title: t.saved?.title || 'Sleeping tab',
      url: t.saved?.url || '',
      favicon: t.favicon || null,
      loading: false,
      canGoBack: false,
      canGoForward: false,
      pinUrl: t.pinUrl || null,
      incognito: !!t.incognito,
      sleeping: true,
      groupEid: t.groupEid || null,
    };
  }
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
    incognito: !!t.incognito,
    sleeping: false,
    groupEid: t.groupEid || null,
  };
}

function pushState() {
  if (!win) return;
  syncGroupEntries();
  try {
    updateNowPlaying();
  } catch {}
  win.webContents.send('state', {
    tabs: tabOrder.map((id) => tabState(tabs.get(id))),
    activeTabId,
    bookmarks,
    pins,
    groups,
  });
}

// Incognito: an in-memory partition — cookies, storage, and cache are never
// written to disk and are wiped when the last incognito tab closes.
let incogSes = null;

function getIncognitoSession() {
  if (incogSes) return incogSes;
  incogSes = session.fromPartition('incognito'); // no "persist:" → memory only
  setupPermissions(incogSes);
  setupDownloads(incogSes);
  if (blocker && appSettings.adblockEnabled) {
    enableAdblockOn(incogSes);
  }
  return incogSes;
}

// Ghostery registers global ipcMain handlers on enable and throws if they
// already exist (i.e. when enabling on a second session) — clear them first,
// the re-registered handlers behave identically for every session.
function enableAdblockOn(ses) {
  if (!blocker) return;
  ipcMain.removeHandler('@ghostery/adblocker/inject-cosmetic-filters');
  ipcMain.removeHandler('@ghostery/adblocker/is-mutation-observer-enabled');
  try {
    blocker.enableBlockingInSession(ses);
  } catch (err) {
    console.error('Adblock enable failed:', err.message);
  }
}

// Builds the live Chromium view for a tab. Called on create and on wake.
function buildView(t, url) {
  const isInternal = url.startsWith('file://');
  if (t.incognito) getIncognitoSession();
  const view = new WebContentsView({
    webPreferences: {
      sandbox: true,
      contextIsolation: true,
      ...(t.incognito ? { partition: 'incognito' } : {}),
      preload: path.join(
        __dirname,
        isInternal ? 'internal-preload.js' : 'page-preload.js'
      ),
    },
  });
  t.view = view;
  t.sleeping = false;
  const id = t.id;
  const incognito = t.incognito;

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
      createTab(details.url, details.disposition === 'foreground-tab', incognito);
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
  // incognito tabs never touch history
  wc.on('did-navigate', (_e, navUrl) => {
    t.didAutoRetry = false; // each navigation gets its own one retry
    if (!t.incognito) recordHistory(wc, navUrl);
  });
  wc.on('did-navigate-in-page', (_e, navUrl, isMain) => {
    if (isMain && !t.incognito) recordHistory(wc, navUrl);
  });
  wc.on('context-menu', (_e, p) => showPageContextMenu(wc, p));
  // Auto-recover transient main-frame load failures (the "had to reload"
  // cases) — retry once, then leave it alone so real errors still surface.
  wc.on('did-fail-load', (_e, errorCode, _desc, _url, isMainFrame) => {
    if (!isMainFrame) return;
    if (errorCode === -3) return; // ERR_ABORTED (user navigated away)
    if (t.didAutoRetry) return;
    t.didAutoRetry = true;
    setTimeout(() => {
      if (t.view && !t.view.webContents.isDestroyed()) t.view.webContents.reload();
    }, 400);
  });
  wc.on('did-finish-load', () => {
    t.didAutoRetry = false; // reset for the next navigation
  });
  wc.on('media-started-playing', () => {
    t.mediaPlaying = true;
    t.mediaTs = Date.now();
    updateNowPlaying();
  });
  wc.on('media-paused', () => {
    t.mediaPlaying = false;
    updateNowPlaying();
  });

  wc.loadURL(url);
  return view;
}

// ---------------------------------------------------------------------------
// Now Playing — sidebar media controls for whichever tab has sound
// ---------------------------------------------------------------------------

let lastNowPlaying = '';

function nowPlayingTab() {
  let best = null;
  for (const t of tabs.values()) {
    if (!t.view) continue;
    const playing = t.mediaPlaying || t.view.webContents.isCurrentlyAudible();
    if (!playing && !t.mediaTs) continue;
    if (!playing) continue;
    if (!best || (t.mediaTs || 0) > (best.mediaTs || 0)) best = t;
  }
  // keep showing a paused widget for the most recent media tab
  if (!best) {
    for (const t of tabs.values()) {
      if (!t.view || !t.mediaTs) continue;
      if (!best || t.mediaTs > best.mediaTs) best = t;
    }
  }
  return best;
}

function updateNowPlaying() {
  if (!win) return;
  const t = nowPlayingTab();
  const payload = t
    ? {
        id: t.id,
        title: t.view.webContents.getTitle() || 'Media',
        favicon: t.favicon || null,
        playing: !!(t.mediaPlaying || t.view.webContents.isCurrentlyAudible()),
      }
    : null;
  const key = JSON.stringify(payload);
  if (key === lastNowPlaying) return;
  lastNowPlaying = key;
  win.webContents.send('now-playing', payload);
}

const MEDIA_TOGGLE = `(() => {
  const els = [...document.querySelectorAll('video,audio')];
  const m = els.find((x) => !x.paused) || els[0];
  if (m) m.paused ? m.play() : m.pause();
})()`;

ipcMain.on('media-toggle', (_e, id) => {
  const t = tabs.get(id);
  if (t?.view) t.view.webContents.executeJavaScript(MEDIA_TOGGLE, true).catch(() => {});
});
ipcMain.on('media-back-to-tab', (_e, id) => {
  if (tabs.has(id)) activateTab(id); // activateTab already exits PiP
});
ipcMain.on('media-pip', (_e, id) => {
  const t = tabs.get(id);
  if (t?.view) runPiP(t.view.webContents, PIP_TOGGLE);
});

function createTab(url = NEWTAB_URL, activate = true, incognito = false) {
  const id = nextTabId++;
  const t = {
    id,
    view: null,
    favicon: null,
    incognito,
    sleeping: false,
    saved: null,
    lastActive: Date.now(),
    groupEid: null,
  };
  tabs.set(id, t);
  tabOrder.push(id);
  buildView(t, url);
  if (activate) activateTab(id);
  else pushState();
  return id;
}

// ---------------------------------------------------------------------------
// Tab sleeping — purge memory of idle background tabs
// ---------------------------------------------------------------------------

function sleepTab(id) {
  const t = tabs.get(id);
  if (!t || t.sleeping || !t.view || id === activeTabId) return;
  const wc = t.view.webContents;
  const url = wc.getURL();
  if (!url || url.startsWith('file://')) return; // internal pages are cheap
  if (wc.isCurrentlyAudible()) return; // don't kill music
  t.saved = { url, title: wc.getTitle() || url };
  t.sleeping = true;
  wc.close();
  t.view = null;
  pushState();
}

function wakeTab(t) {
  if (!t.sleeping || t.view) return;
  buildView(t, t.saved?.url || NEWTAB_URL);
  t.saved = null;
}

setInterval(() => {
  const hours = Number(appSettings.tabSleepHours);
  if (!hours) return; // "never"
  const cutoff = Date.now() - hours * 60 * 60 * 1000;
  for (const t of tabs.values()) {
    if (t.id !== activeTabId && !t.sleeping && t.lastActive < cutoff) {
      sleepTab(t.id);
    }
  }
}, 5 * 60 * 1000);

// Picture-in-picture: pops the largest playing video out (auto on tab switch,
// or manually via the View menu). Runs with a synthetic user gesture.
const PIP_ENTER = `(async () => {
  const v = [...document.querySelectorAll('video')]
    .filter((x) => !x.paused && !x.ended && x.readyState > 2)
    .sort((a, b) => b.videoWidth * b.videoHeight - a.videoWidth * a.videoHeight)[0];
  if (v && document.pictureInPictureElement !== v) {
    try { await v.requestPictureInPicture(); } catch {}
  }
})()`;
const PIP_EXIT = `(async () => {
  if (document.pictureInPictureElement) {
    try { await document.exitPictureInPicture(); } catch {}
  }
})()`;
const PIP_TOGGLE = `(async () => {
  if (document.pictureInPictureElement) {
    try { await document.exitPictureInPicture(); return; } catch {}
  }
  const v = [...document.querySelectorAll('video')]
    .filter((x) => !x.paused && !x.ended && x.readyState > 2)
    .sort((a, b) => b.videoWidth * b.videoHeight - a.videoWidth * a.videoHeight)[0];
  if (v) { try { await v.requestPictureInPicture(); } catch {} }
})()`;

function runPiP(wc, code) {
  if (!wc || wc.getURL().startsWith('file://')) return;
  wc.executeJavaScript(code, true).catch(() => {});
}

function activateTab(id) {
  const t = tabs.get(id);
  if (!t || !win) return;
  const prev = activeTabId && activeTabId !== id ? tabs.get(activeTabId) : null;
  if (prev?.view) {
    win.contentView.removeChildView(prev.view);
    // leaving a tab with playing video → pop it out automatically
    if (appSettings.autoPip) runPiP(prev.view.webContents, PIP_ENTER);
  }
  activeTabId = id;
  wakeTab(t);
  win.contentView.addChildView(t.view);
  t.lastActive = Date.now();
  applyBounds();
  t.view.webContents.focus();
  // returning to the tab → bring its video back inline
  if (appSettings.autoPip) runPiP(t.view.webContents, PIP_EXIT);
  pushState();
}

function closeTab(id) {
  const t = tabs.get(id);
  if (!t) return;
  const idx = tabOrder.indexOf(id);
  tabOrder = tabOrder.filter((x) => x !== id);
  if (activeTabId === id) {
    if (t.view) win.contentView.removeChildView(t.view);
    activeTabId = null;
    const next = tabOrder[Math.min(idx, tabOrder.length - 1)];
    if (next) activateTab(next);
  }
  if (t.view) t.view.webContents.close();
  tabs.delete(id);
  // last incognito tab gone → wipe the in-memory session like Chrome does
  if (t.incognito && incogSes && ![...tabs.values()].some((x) => x.incognito)) {
    incogSes.clearStorageData().catch(() => {});
    incogSes.clearCache().catch(() => {});
  }
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
    if (tabURL(tabs.get(id)) === url) {
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
    if (view && view.webContents.getURL().startsWith('file://')) {
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
  if (!t || t.incognito) return; // incognito tabs leave no trace, including pins
  const url = tabURL(t);
  if (!url || url.startsWith('file://')) return;
  if (pins.some((p) => p.url === url)) return;
  const title = t.sleeping ? t.saved?.title : t.view.webContents.getTitle();
  pins.push({ title: title || url, url, favicon: t.favicon });
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
    if (t.pinUrl === url || tabURL(t) === url) return t;
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

// ---------------------------------------------------------------------------
// Tab groups — named, persistent collections; entries survive tab close
// ---------------------------------------------------------------------------

let groups = []; // [{ id, name, entries: [{ eid, title, url, favicon }] }]
let nextGroupId = 1;
let nextEntryId = 1;

function saveGroups() {
  saveSettings({ groups });
}

function loadGroups(settings) {
  groups = Array.isArray(settings.groups) ? settings.groups : [];
  for (const g of groups) {
    nextGroupId = Math.max(nextGroupId, g.id + 1);
    for (const e of g.entries) nextEntryId = Math.max(nextEntryId, e.eid + 1);
  }
}

function groupEntry(eid) {
  for (const g of groups) {
    const e = g.entries.find((x) => x.eid === eid);
    if (e) return { group: g, entry: e };
  }
  return null;
}

function tabForEntry(eid) {
  for (const t of tabs.values()) if (t.groupEid === eid) return t;
  return null;
}

function addTabToGroup(tabId, groupId) {
  const t = tabs.get(tabId);
  if (!t || t.incognito) return;
  const g = groups.find((x) => x.id === groupId);
  if (!g) return;
  const url = tabURL(t);
  if (!url || url.startsWith('file://')) return;
  const title =
    (t.sleeping ? t.saved?.title : t.view.webContents.getTitle()) || url;
  const eid = nextEntryId++;
  g.entries.push({ eid, title, url, favicon: t.favicon });
  t.groupEid = eid;
  saveGroups();
  pushState();
}

function createGroupWithTab(tabId) {
  const g = { id: nextGroupId++, name: `Group ${groups.length + 1}`, entries: [] };
  groups.push(g);
  addTabToGroup(tabId, g.id);
  win?.webContents.send('rename-group-start', g.id); // let the user name it now
}

function openGroupEntry(gid, eid) {
  const live = tabForEntry(eid);
  if (live) {
    activateTab(live.id);
    return;
  }
  const found = groupEntry(eid);
  if (!found) return;
  const id = createTab(found.entry.url, true);
  tabs.get(id).groupEid = eid;
  pushState();
}

function closeGroupEntry(eid) {
  const live = tabForEntry(eid);
  if (live) closeTab(live.id); // entry stays in the group, tab sleeps away
}

function removeGroupEntry(gid, eid) {
  const g = groups.find((x) => x.id === gid);
  if (!g) return;
  g.entries = g.entries.filter((e) => e.eid !== eid);
  const live = tabForEntry(eid);
  if (live) live.groupEid = null; // back to the regular tab list
  saveGroups();
  pushState();
}

function deleteGroup(gid) {
  const g = groups.find((x) => x.id === gid);
  if (!g) return;
  for (const e of g.entries) {
    const live = tabForEntry(e.eid);
    if (live) live.groupEid = null;
  }
  groups = groups.filter((x) => x.id !== gid);
  saveGroups();
  pushState();
}

// keep entry titles/urls in sync as their live tabs navigate
function syncGroupEntries() {
  let dirty = false;
  for (const t of tabs.values()) {
    if (!t.groupEid || t.sleeping || !t.view) continue;
    const found = groupEntry(t.groupEid);
    if (!found) {
      t.groupEid = null;
      continue;
    }
    const url = t.view.webContents.getURL();
    const title = t.view.webContents.getTitle();
    if (url && !url.startsWith('file://') && found.entry.url !== url) {
      found.entry.url = url;
      dirty = true;
    }
    if (title && found.entry.title !== title) {
      found.entry.title = title;
      dirty = true;
    }
    if (t.favicon && found.entry.favicon !== t.favicon) {
      found.entry.favicon = t.favicon;
      dirty = true;
    }
  }
  if (dirty) saveGroups();
}

function showTabContextMenu(id) {
  const t = tabs.get(id);
  if (!t) return;
  const url = tabURL(t);
  const isPinned = pins.some((p) => p.url === url);
  const isWeb = url && !url.startsWith('file://') && !t.incognito;
  Menu.buildFromTemplate([
    {
      label: isPinned ? 'Unpin' : 'Pin Tab',
      enabled: isWeb,
      click: () => (isPinned ? unpin(url) : pinTab(id)),
    },
    {
      label: 'Move to Group',
      enabled: isWeb && !t.groupEid,
      submenu: [
        ...groups.map((g) => ({
          label: g.name,
          click: () => addTabToGroup(id, g.id),
        })),
        ...(groups.length ? [{ type: 'separator' }] : []),
        { label: 'New Group…', click: () => createGroupWithTab(id) },
      ],
    },
    {
      label: 'Duplicate Tab',
      enabled: isWeb,
      click: () => createTab(url, true),
    },
    {
      label: 'Sleep Tab',
      enabled: isWeb && !t.sleeping && id !== activeTabId,
      click: () => sleepTab(id),
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
    // offer saved credentials for this site on editable fields
    const creds = credsForOrigin(wc.getURL());
    if (creds.length) {
      items.push(
        {
          label: 'Fill Password',
          submenu: creds.map((c) => ({
            label: c.username ? `${c.username}` : c.site,
            click: () => wc.insertText(c.password),
          })),
        },
        {
          label: 'Fill Username',
          submenu: creds
            .filter((c) => c.username)
            .map((c) => ({
              label: c.username,
              click: () => wc.insertText(c.username),
            })),
        },
        { type: 'separator' }
      );
    }
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
      // stale service workers + caches from before UA/adblock changes are the
      // usual cause of "this page isn't available" on FB/IG — nuke and reload
      label: 'Fix This Site (Clear Data & Reload)',
      click: async () => {
        try {
          const origin = new URL(wc.getURL()).origin;
          await wc.session.clearStorageData({ origin });
          await wc.session.clearCache();
          wc.reloadIgnoringCache();
        } catch {}
      },
    },
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

// History is encrypted at rest with safeStorage (Keychain-derived key on
// macOS, DPAPI on Windows) — the file on disk is unreadable without the
// user's OS account.
const { safeStorage } = require('electron');

function encryptToFile(file, data) {
  const json = JSON.stringify(data);
  try {
    if (safeStorage.isEncryptionAvailable()) {
      fs.writeFileSync(file, safeStorage.encryptString(json));
    } else {
      fs.writeFileSync(file, json); // rare fallback: no OS keystore available
    }
  } catch {}
}

function decryptFromFile(file) {
  const buf = fs.readFileSync(file);
  try {
    return JSON.parse(safeStorage.decryptString(buf));
  } catch {
    return JSON.parse(buf.toString('utf8')); // plaintext fallback / migration
  }
}

const HISTORY_URL = `file://${path.join(__dirname, 'ui', 'history.html')}`;
const historyPath = () => path.join(app.getPath('userData'), 'history.bin');
const legacyHistoryPath = () => path.join(app.getPath('userData'), 'history.json');
let history = [];
let historySaveTimer = null;

function loadHistory() {
  try {
    history = decryptFromFile(historyPath());
  } catch {
    // migrate pre-encryption plaintext history, then remove it
    try {
      history = JSON.parse(fs.readFileSync(legacyHistoryPath(), 'utf8'));
      encryptToFile(historyPath(), history);
      fs.unlinkSync(legacyHistoryPath());
    } catch {
      history = [];
    }
  }
}

function saveHistorySoon() {
  clearTimeout(historySaveTimer);
  historySaveTimer = setTimeout(() => encryptToFile(historyPath(), history), 1500);
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
// Password vault — encrypted locally with safeStorage, never leaves the Mac
// ---------------------------------------------------------------------------

const PASSWORDS_URL = `file://${path.join(__dirname, 'ui', 'passwords.html')}`;
const vaultPath = () => path.join(app.getPath('userData'), 'vault.bin');
let vault = []; // [{ id, site, username, password }]
let nextCredId = 1;

function loadVault() {
  try {
    vault = decryptFromFile(vaultPath());
    nextCredId = Math.max(0, ...vault.map((c) => c.id)) + 1;
  } catch {
    vault = [];
  }
}

function saveVault() {
  encryptToFile(vaultPath(), vault);
}

function credsForOrigin(url) {
  let host;
  try {
    host = new URL(url).hostname.replace(/^www\./, '');
  } catch {
    return [];
  }
  return vault.filter((c) => {
    try {
      const ch = (c.site.includes('://') ? new URL(c.site).hostname : c.site)
        .replace(/^www\./, '');
      return ch === host || host.endsWith('.' + ch) || ch.endsWith('.' + host);
    } catch {
      return false;
    }
  });
}

// vault IPC is restricted to the passwords page itself
function vaultSenderOk(e) {
  return e.sender.getURL() === PASSWORDS_URL;
}

ipcMain.handle('vault-list', (e) => (vaultSenderOk(e) ? vault : []));
ipcMain.on('vault-add', (e, { site, username, password }) => {
  if (!vaultSenderOk(e) || !site || !password) return;
  vault.push({ id: nextCredId++, site, username: username || '', password });
  saveVault();
  e.sender.send('vault', vault);
});
ipcMain.on('vault-delete', (e, id) => {
  if (!vaultSenderOk(e)) return;
  vault = vault.filter((c) => c.id !== id);
  saveVault();
  e.sender.send('vault', vault);
});
ipcMain.on('vault-import-csv', (e, csv) => {
  if (!vaultSenderOk(e)) return;
  // Chrome/Safari/Firefox export format: name/url/username/password columns
  const lines = String(csv).split(/\r?\n/).filter(Boolean);
  if (!lines.length) return;
  const header = lines[0].toLowerCase().split(',');
  const idx = (names) => header.findIndex((h) => names.includes(h.trim().replace(/"/g, '')));
  const urlIdx = idx(['url', 'website', 'origin']);
  const userIdx = idx(['username', 'username field', 'login']);
  const passIdx = idx(['password']);
  if (passIdx < 0) return;
  const parseLine = (line) => {
    const out = [];
    let cur = '';
    let inQ = false;
    for (const ch of line) {
      if (ch === '"') inQ = !inQ;
      else if (ch === ',' && !inQ) {
        out.push(cur);
        cur = '';
      } else cur += ch;
    }
    out.push(cur);
    return out;
  };
  let added = 0;
  for (const line of lines.slice(1)) {
    const cols = parseLine(line);
    const site = urlIdx >= 0 ? cols[urlIdx] : '';
    const password = cols[passIdx];
    if (!site || !password) continue;
    const username = userIdx >= 0 ? cols[userIdx] : '';
    if (vault.some((c) => c.site === site && c.username === username)) continue;
    vault.push({ id: nextCredId++, site, username, password });
    added++;
  }
  saveVault();
  e.sender.send('vault', vault);
  e.sender.send('vault-imported', added);
});

// Offer to save credentials captured from a login form submission.
let credPromptOpen = false;

ipcMain.on('cred-captured', async (e, { origin, username, password }) => {
  if (credPromptOpen || !origin || !password) return;
  // never prompt for incognito tabs
  if (e.sender.session !== session.defaultSession) return;
  if ((appSettings.neverSavePasswords || []).includes(origin)) return;
  const exists = vault.some(
    (c) =>
      credsForOrigin(origin).includes(c) &&
      c.username === username &&
      c.password === password
  );
  if (exists) return;
  const updating = credsForOrigin(origin).some((c) => c.username === username);

  credPromptOpen = true;
  try {
    const host = origin.replace(/^https?:\/\//, '');
    const { response } = await dialog.showMessageBox(win, {
      type: 'question',
      message: updating
        ? `Update saved password for ${host}?`
        : `Save password for ${host}?`,
      detail: username ? `Account: ${username}` : undefined,
      buttons: [updating ? 'Update' : 'Save', 'Not Now', 'Never for This Site'],
      defaultId: 0,
      cancelId: 1,
    });
    if (response === 0) {
      const prev = credsForOrigin(origin).find((c) => c.username === username);
      if (prev) prev.password = password;
      else vault.push({ id: nextCredId++, site: origin, username, password });
      saveVault();
    } else if (response === 2) {
      const never = appSettings.neverSavePasswords || [];
      never.push(origin);
      applySetting('neverSavePasswords', never);
    }
  } finally {
    credPromptOpen = false;
  }
});

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
    // a download can't still be running across a restart — anything stuck in
    // 'progressing' is a ghost from a crash; mark it so the UI stops spinning
    for (const d of downloadList) {
      if (d.state === 'progressing') d.state = 'interrupted';
    }
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
    if (view && view.webContents.getURL().startsWith('file://')) {
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

function setupDownloads(ses) {
  ses.on('will-download', (_e, item) => {
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
    saveDownloads(); // survive a crash mid-download (shows as interrupted)

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
// relay page text selections to the chrome (AI panel uses them when open)
ipcMain.on('page-selection', (e, text) => {
  // only the active tab's selection matters
  const t = tabs.get(activeTabId);
  if (t?.view && t.view.webContents.id === e.sender.id) {
    win?.webContents.send('page-selection', text);
  }
});

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

ipcMain.handle('get-suggestions', async (e, q) => {
  const query = String(q || '').trim();
  if (!query) return { openTabs: [], history: [], bookmarks: [], web: [] };
  const lower = query.toLowerCase();

  // open tabs matching the query → "switch to tab"
  const senderId = e.sender.id;
  const openTabs = [];
  for (const id of tabOrder) {
    if (openTabs.length >= 3) break;
    const t = tabs.get(id);
    const url = tabURL(t);
    if (!url || url.startsWith('file://') || t.incognito) continue;
    if (t.view && t.view.webContents.id === senderId) continue; // not myself
    const title = t.sleeping
      ? t.saved?.title || ''
      : t.view.webContents.getTitle() || '';
    if (url.toLowerCase().includes(lower) || title.toLowerCase().includes(lower)) {
      openTabs.push({ id, title: title || url, url });
    }
  }

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

  return { openTabs, history: hist, bookmarks: bms, web };
});

// "Switch to tab" from a new-tab page: activate the target and close the
// now-orphaned new tab the user was typing in.
ipcMain.on('switch-to-tab', (e, id) => {
  if (!tabs.has(id)) return;
  let senderTabId = null;
  for (const t of tabs.values()) {
    if (t.view && t.view.webContents.id === e.sender.id) {
      senderTabId = t.id;
      break;
    }
  }
  activateTab(id);
  if (senderTabId && tabURL(tabs.get(senderTabId)) === NEWTAB_URL) {
    closeTab(senderTabId);
  }
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

function setupPermissions(ses) {
  const autoAllow = new Set([
    'fullscreen',
    'clipboard-sanitized-write',
    'pointerLock',
    'keyboardLock',
    'window-management',
    'publickey-credentials-get', // WebAuthn / passkeys
    'publickey-credentials-create',
  ]);
  // Notifications: a site calls Notification.permission FIRST (sync check) and
  // if it sees 'denied' it shows "blocked, enable in settings" and never asks.
  // So we report notifications as allowed browser-wide by default (toggle in
  // Settings), unless the site is explicitly blocked. Then native notifications
  // just work, exactly like a normal browser.
  function notifAllowed(origin) {
    const saved = (appSettings.permissions || {})[origin]?.notifications;
    if (saved !== undefined) return saved;
    return appSettings.webNotifications !== false;
  }

  // synchronous probes (e.g. WebAuthn availability checks, Notification.permission)
  ses.setPermissionCheckHandler((_wc, permission, origin) => {
    if (autoAllow.has(permission)) return true;
    if (permission === 'notifications') return notifAllowed(origin);
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
    // notifications follow the browser-wide setting (+ per-site override),
    // no per-request dialog — matches how Chrome/Safari behave once allowed
    if (permission === 'notifications') return callback(notifAllowed(origin));
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
// Import bookmarks/pins from other browsers (Chrome, Arc, Dia, Safari, …)
// ---------------------------------------------------------------------------

const { execFile } = require('child_process');

function importSources() {
  const home = app.getPath('home');
  const appSup = path.join(home, 'Library', 'Application Support');
  const candidates = [
    { name: 'Chrome', kind: 'chromium', path: path.join(appSup, 'Google/Chrome/Default/Bookmarks') },
    { name: 'Arc', kind: 'chromium', path: path.join(appSup, 'Arc/User Data/Default/Bookmarks') },
    { name: 'Dia', kind: 'chromium', path: path.join(appSup, 'Dia/User Data/Default/Bookmarks') },
    { name: 'Edge', kind: 'chromium', path: path.join(appSup, 'Microsoft Edge/Default/Bookmarks') },
    { name: 'Brave', kind: 'chromium', path: path.join(appSup, 'BraveSoftware/Brave-Browser/Default/Bookmarks') },
    { name: 'Vivaldi', kind: 'chromium', path: path.join(appSup, 'Vivaldi/Default/Bookmarks') },
    { name: 'Safari', kind: 'safari', path: path.join(home, 'Library/Safari/Bookmarks.plist') },
  ];
  return candidates.filter((c) => {
    try {
      fs.accessSync(c.path, fs.constants.R_OK);
      return true;
    } catch {
      return false;
    }
  });
}

function parseChromiumBookmarks(file) {
  const json = JSON.parse(fs.readFileSync(file, 'utf8'));
  const out = [];
  const walk = (n) => {
    if (!n) return;
    if (n.type === 'url' && /^https?:/.test(n.url)) {
      out.push({ title: n.name || n.url, url: n.url });
    }
    (n.children || []).forEach(walk);
  };
  Object.values(json.roots || {}).forEach(walk);
  return out;
}

function parseSafariBookmarks(file) {
  return new Promise((resolve, reject) => {
    execFile('plutil', ['-convert', 'json', '-o', '-', file], { maxBuffer: 64 * 1024 * 1024 }, (err, stdout) => {
      if (err) return reject(err);
      const out = [];
      const walk = (n) => {
        if (!n) return;
        if (n.WebBookmarkType === 'WebBookmarkTypeLeaf' && /^https?:/.test(n.URLString || '')) {
          out.push({ title: n.URIDictionary?.title || n.URLString, url: n.URLString });
        }
        (n.Children || []).forEach(walk);
      };
      walk(JSON.parse(stdout));
      resolve(out);
    });
  });
}

// Netscape bookmarks HTML — the export format every browser supports
function parseBookmarksHTML(html) {
  const out = [];
  const re = /<a[^>]*href="(https?:[^"]+)"[^>]*>([^<]*)<\/a>/gi;
  let m;
  while ((m = re.exec(html))) {
    const url = m[1].replace(/&amp;/g, '&');
    out.push({ title: (m[2] || url).trim() || url, url });
  }
  return out;
}

function mergeImported(items, target) {
  let added = 0;
  if (target === 'pins') {
    for (const it of items) {
      if (!pins.some((p) => p.url === it.url)) {
        pins.push({ title: it.title, url: it.url, favicon: null });
        added++;
      }
    }
    saveSettings({ pins });
  } else {
    for (const it of items) {
      if (!bookmarks.some((b) => b.url === it.url)) {
        bookmarks.push({ title: it.title, url: it.url });
        added++;
      }
    }
    saveSettings({ bookmarks });
    broadcastBookmarks();
  }
  pushState();
  return added;
}

ipcMain.handle('import-sources', () => importSources());
ipcMain.handle('import-from-browser', async (_e, { path: file, kind, target }) => {
  try {
    const items =
      kind === 'safari'
        ? await parseSafariBookmarks(file)
        : parseChromiumBookmarks(file);
    return { ok: true, added: mergeImported(items, target), found: items.length };
  } catch (err) {
    return { ok: false, error: err.message };
  }
});
ipcMain.handle('import-html', (_e, { html, target }) => {
  try {
    const items = parseBookmarksHTML(html);
    return { ok: true, added: mergeImported(items, target), found: items.length };
  } catch (err) {
    return { ok: false, error: err.message };
  }
});

// ---------------------------------------------------------------------------
// Ad blocking
// ---------------------------------------------------------------------------

// Sites whose own content endpoints look like trackers to filter lists, so
// blocking breaks them (FB/IG feeds die after first paint, etc). $document
// exceptions disable ALL blocking on these origins — their ads are
// first-party and unblockable anyway, so we trade nothing real for working
// feeds. Everywhere else keeps full ad/tracker blocking.
const ADBLOCK_EXCEPTIONS = [
  '@@||facebook.com^$document',
  '@@||fbcdn.net^$document',
  '@@||instagram.com^$document',
  '@@||cdninstagram.com^$document',
  '@@||messenger.com^$document',
  '@@||threads.net^$document',
  '@@||whatsapp.com^$document',
];

async function setupAdblock() {
  try {
    const { ElectronBlocker, adsAndTrackingLists } = require('@ghostery/adblocker-electron');
    // COSMETIC FILTERING FULLY OFF — it was hiding legit site UI (the YouTube
    // masthead logo/menu). Cosmetic rules hide DOM elements by selector and
    // false-positive on real content; we drop them entirely. NETWORK blocking
    // stays fully on, so ad/tracker *requests* are still blocked and ads don't
    // load — Breeze just never hides arbitrary page elements anymore.
    // Fresh cache file (v3) so the new config is honored, not a stale engine.
    blocker = await ElectronBlocker.fromLists(
      fetch,
      adsAndTrackingLists,
      { loadCosmeticFilters: false },
      {
        path: path.join(app.getPath('userData'), 'adblock-engine-v3.bin'),
        read: fs.promises.readFile,
        write: fs.promises.writeFile,
      }
    );
    try {
      blocker.updateFromDiff({ added: ADBLOCK_EXCEPTIONS });
    } catch (e) {
      console.error('Adblock exceptions failed:', e.message);
    }
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
// Web lookup for the AI (Tavily) — key lives in .env / env var, never in git
// ---------------------------------------------------------------------------

function getTavilyKey() {
  if (process.env.TAVILY_API_KEY) return process.env.TAVILY_API_KEY;
  for (const file of [
    path.join(__dirname, '.env'),
    path.join(app.getPath('userData'), '.env'),
  ]) {
    try {
      const m = fs.readFileSync(file, 'utf8').match(/TAVILY_API_KEY\s*=\s*(\S+)/);
      if (m) return m[1];
    } catch {}
  }
  return null;
}

async function tavilySearch(query) {
  const key = getTavilyKey();
  if (!key) return null;
  try {
    const ctrl = new AbortController();
    const to = setTimeout(() => ctrl.abort(), 9000);
    const res = await fetch('https://api.tavily.com/search', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ api_key: key, query, max_results: 5 }),
      signal: ctrl.signal,
    });
    clearTimeout(to);
    const data = await res.json();
    const results = data.results || [];
    if (!results.length) return null;
    return results
      .map(
        (r, i) =>
          `[${i + 1}] ${r.title}\n${r.url}\n${(r.content || '').slice(0, 500)}`
      )
      .join('\n\n');
  } catch {
    return null;
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
  model: null,
  llama: null,
  sequence: null,
  LlamaChatSession: null,
  abort: null,
  lastCtxUrl: null,
  idleTimer: null,
};

// The 3B model holds ~2GB resident and the Metal backend spins the GPU/fans.
// Unload it after the assistant has been idle/closed for a while; it reloads
// transparently on next use.
const AI_IDLE_MS = 4 * 60 * 1000;

function disposeAI() {
  clearTimeout(ai.idleTimer);
  if (ai.generating || ai.loading) return;
  try {
    ai.session?.dispose();
    ai.sequence?.dispose();
    ai.context?.dispose();
    ai.model?.dispose();
  } catch {}
  ai.session = ai.sequence = ai.context = ai.model = null;
  ai.ready = false;
  ai.lastCtxUrl = null;
}

function scheduleAIIdleUnload() {
  clearTimeout(ai.idleTimer);
  // only unload while the assistant panel is closed
  if (assistantVisible) return;
  ai.idleTimer = setTimeout(disposeAI, AI_IDLE_MS);
}

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
    ai.llama = ai.llama || (await getLlama());
    ai.model = await ai.llama.loadModel({ modelPath });
    // smaller context = much less RAM; plenty for page Q&A
    ai.context = await ai.model.createContext({ contextSize: { max: 4096 } });
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

function buildSystemPrompt() {
  const name = (appSettings.userName || '').trim();
  const custom = (appSettings.aiInstructions || '').trim();
  let p =
    "You are Breeze AI — the assistant baked into the Breeze browser. You're " +
    'witty, warm, and a little cheeky, but never at the expense of being genuinely ' +
    'useful. Think clever best friend who happens to know everything: you crack the ' +
    'occasional dry joke, you have opinions, and you keep it real. Be conversational ' +
    'and give answers room to breathe — a few helpful sentences, not a terse one-liner ' +
    "— but don't ramble or pad. When page content or web results are provided, ground " +
    'your answer in them and cite URLs when you use web sources. Everything you do runs ' +
    "locally on the user's Mac, and you're quietly proud of that — their data never leaves.";
  if (name) p += `\n\nThe user's name is ${name}. Address them by name occasionally, naturally.`;
  if (custom) p += `\n\nThe user gave you these standing instructions — follow them: ${custom}`;
  return p;
}

function newChat() {
  try {
    ai.session?.dispose();
    ai.sequence?.dispose();
  } catch {}
  ai.sequence = ai.context.getSequence();
  ai.session = new ai.LlamaChatSession({
    contextSequence: ai.sequence,
    systemPrompt: buildSystemPrompt(),
  });
  ai.lastCtxUrl = null;
}

// Smart extraction: main/article content over nav clutter; site-specific
// handling for YouTube (title + channel + description, not "related videos").
const EXTRACT_CONTEXT = `(() => {
  const meta =
    document.querySelector('meta[name="description"]')?.content ||
    document.querySelector('meta[property="og:description"]')?.content || '';

  if (location.hostname.endsWith('youtube.com') && location.pathname === '/watch') {
    const vidTitle =
      document.querySelector('h1.ytd-watch-metadata')?.innerText ||
      document.querySelector('#title h1')?.innerText || document.title;
    const channel =
      document.querySelector('ytd-channel-name #text a, ytd-channel-name a')?.innerText || '';
    try { document.querySelector('tp-yt-paper-button#expand, #expand')?.click(); } catch {}
    const desc =
      document.querySelector('#description-inline-expander')?.innerText ||
      document.querySelector('#description')?.innerText || meta;
    const comments = [...document.querySelectorAll('#content-text')]
      .slice(0, 5).map((c) => c.innerText).join('\\n· ');
    return 'VIDEO: ' + vidTitle + '\\nCHANNEL: ' + channel +
      '\\nDESCRIPTION:\\n' + desc +
      (comments ? '\\nTOP COMMENTS:\\n· ' + comments : '');
  }

  const root =
    document.querySelector('main') ||
    document.querySelector('article') ||
    document.querySelector('[role="main"]') ||
    document.body;
  let text = root ? root.innerText : '';
  if (!text || text.length < 200) text = document.body ? document.body.innerText : '';
  return (meta ? meta + '\\n\\n' : '') + text;
})()`;

async function getPageContext() {
  const wc = activeWC();
  if (!wc) return null;
  const url = wc.getURL();
  if (!url || url.startsWith('file://')) return null;
  try {
    const text = await wc.executeJavaScript(EXTRACT_CONTEXT, true);
    return { title: wc.getTitle(), url, text: String(text).slice(0, 9000) };
  } catch {
    return null;
  }
}

// --- AI tools: reminders + OpenAI image generation -----------------------

// Parse natural-language reminders: "remind me in 10 minutes to call mom",
// "remind me to stretch in 2 hours". Returns { ms, label } or null.
function parseReminder(text) {
  const m = text.match(/\bremind\s+me\b/i);
  if (!m) return null;
  const t = text.match(/\bin\s+(\d+)\s*(sec|second|min|minute|hour|hr|day)s?\b/i);
  if (!t) return null;
  const n = parseInt(t[1], 10);
  const unit = t[2].toLowerCase();
  const mult = unit.startsWith('sec')
    ? 1000
    : unit.startsWith('min')
    ? 60000
    : unit.startsWith('hour') || unit === 'hr'
    ? 3600000
    : 86400000;
  let label = text
    .replace(/\bremind\s+me\s*(to\s+)?/i, '')
    .replace(/\bin\s+\d+\s*(sec|second|min|minute|hour|hr|day)s?\b/i, '')
    .replace(/\s{2,}/g, ' ')
    .trim();
  if (!label) label = 'Reminder';
  return { ms: n * mult, label, human: `${n} ${unit}${n > 1 ? 's' : ''}` };
}

function scheduleReminder(label, ms) {
  setTimeout(() => {
    try {
      const n = new Notification({
        title: 'Breeze reminder',
        body: label,
        silent: false,
      });
      n.on('click', () => {
        win?.show();
        win?.focus();
      });
      n.show();
    } catch {}
  }, ms);
}

async function openaiImage(prompt) {
  const key = (appSettings.openaiKey || '').trim();
  if (!key) return { error: 'no-key' };
  try {
    const res = await fetch('https://api.openai.com/v1/images/generations', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${key}`,
      },
      body: JSON.stringify({
        model: 'gpt-image-1',
        prompt,
        n: 1,
        size: '1024x1024',
      }),
    });
    const data = await res.json();
    if (data.error) return { error: data.error.message || 'OpenAI error' };
    const d = data.data && data.data[0];
    if (d?.b64_json) return { dataUrl: `data:image/png;base64,${d.b64_json}` };
    if (d?.url) return { url: d.url };
    return { error: 'No image returned' };
  } catch (e) {
    return { error: e.message };
  }
}

ipcMain.on('ai-ask', async (_e, { text, useWeb, useImage, selection }) => {
  if (ai.generating) return;

  // --- Reminder shortcut: handle locally, no model needed ---
  const reminder = parseReminder(text);
  if (reminder) {
    scheduleReminder(reminder.label, reminder.ms);
    win?.webContents.send('ai-tool', { kind: 'reminder', label: `Reminder set for ${reminder.human}` });
    win?.webContents.send(
      'ai-chunk',
      `Done — I'll remind you in ${reminder.human}: "${reminder.label}". 🔔`
    );
    win?.webContents.send('ai-done');
    return;
  }

  // --- Image generation ---
  if (useImage) {
    win?.webContents.send('ai-tool', { kind: 'image', label: 'Generating image…' });
    sendAI({ state: 'generating-image' });
    const img = await openaiImage(text);
    if (img.error === 'no-key') {
      win?.webContents.send(
        'ai-chunk',
        'Add your OpenAI API key in Settings → AI to generate images. 🔑'
      );
    } else if (img.error) {
      win?.webContents.send('ai-chunk', `Image generation failed: ${img.error}`);
    } else {
      win?.webContents.send('ai-image', img.dataUrl || img.url);
    }
    win?.webContents.send('ai-done');
    sendAI({ state: 'ready' });
    return;
  }

  if (!(await ensureAI())) return;
  ai.generating = true;

  let prompt = text;

  // selected page text the user highlighted — make it the focus
  if (selection && selection.trim()) {
    win?.webContents.send('ai-tool', { kind: 'selection', label: 'Using your selected text' });
    prompt = `[The user highlighted this text on the page]\n"${selection.trim().slice(0, 2000)}"\n\n${prompt}`;
  }

  // optional: cross-reference with live web results
  if (useWeb) {
    sendAI({ state: 'searching' });
    win?.webContents.send('ai-tool', { kind: 'web', label: 'Searched the web' });
    const sources = await tavilySearch(text);
    if (sources) {
      prompt =
        `[Web search results — cite these by URL when you use them]\n` +
        `${sources}\n[End web results]\n\n${prompt}`;
    }
  }
  sendAI({ state: 'generating' });

  // page context is always included (refreshed when the page changes)
  {
    const ctx = await getPageContext();
    if (ctx && ctx.url !== ai.lastCtxUrl) {
      win?.webContents.send('ai-tool', { kind: 'page', label: `Reading "${ctx.title}"` });
      prompt =
        `[Current page: "${ctx.title}" — ${ctx.url}]\n` +
        `[Page content]\n${ctx.text}\n[End page content]\n\n${prompt}`;
      ai.lastCtxUrl = ctx.url;
    }
  }

  ai.abort = new AbortController();
  try {
    await ai.session.prompt(prompt, {
      signal: ai.abort.signal,
      // bounded + penalized generation: small local models loop without this.
      // Roomier cap so answers aren't cut short, still safe from runaways.
      maxTokens: 1700,
      temperature: 0.75,
      topP: 0.9,
      repeatPenalty: {
        penalty: 1.18,
        frequencyPenalty: 0.4,
        presencePenalty: 0.3,
        lastTokens: 128,
      },
      onTextChunk: (chunk) => win?.webContents.send('ai-chunk', chunk),
    });
  } catch (err) {
    if (!ai.abort.signal.aborted) {
      // a full context window shows up as endless errors/restarts — recover
      // with a fresh chat instead of leaving the session wedged
      if (/context|sequence|kv|slot/i.test(err.message)) {
        try {
          newChat();
          win?.webContents.send(
            'ai-chunk',
            'This conversation got too long for the model — I started a fresh chat. Ask me again!'
          );
        } catch {
          sendAI({ state: 'error', message: err.message });
        }
      } else {
        sendAI({ state: 'error', message: err.message });
      }
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

// 'system' follows the OS; otherwise the explicit choice. The renderer always
// receives a concrete 'light'/'dark' (the effective theme).
function effectiveTheme() {
  const t = appSettings.theme || 'light';
  if (t === 'system') return nativeTheme.shouldUseDarkColors ? 'dark' : 'light';
  return t;
}

function applyTheme(theme) {
  nativeTheme.themeSource = theme === 'system' ? 'system' : theme;
  const eff = effectiveTheme();
  if (win) {
    win.setBackgroundColor(eff === 'dark' ? '#16161a' : '#f2f0ed');
    win.webContents.send('theme', eff);
  }
  // internal pages (new tab, settings) follow instantly via their preload
  for (const { view } of tabs.values()) {
    if (view && view.webContents.getURL().startsWith('file://')) {
      view.webContents.send('theme', eff);
    }
  }
}

// when in System mode, re-broadcast as the OS flips light/dark
nativeTheme.on('updated', () => {
  if (appSettings.theme === 'system') applyTheme('system');
});

function applySetting(key, value) {
  appSettings[key] = value;
  saveSettings({ [key]: value });
  if (key === 'theme') applyTheme(value);
  if (key === 'urlBarPosition') layout();
  if (key === 'adblockEnabled' && blocker) {
    const sessions = [session.defaultSession, ...(incogSes ? [incogSes] : [])];
    for (const ses of sessions) {
      if (value) enableAdblockOn(ses);
      else {
        try {
          blocker.disableBlockingInSession(ses);
        } catch {}
      }
    }
  }
  broadcastSettings();
}

function createWindow() {
  const settings = loadSettings();
  appSettings = { ...DEFAULT_SETTINGS, ...settings };
  sidebarVisible = appSettings.sidebarVisible !== false;
  bookmarks = Array.isArray(settings.bookmarks) ? settings.bookmarks : [];
  pins = Array.isArray(settings.pins) ? settings.pins : [];
  loadGroups(settings);
  sidebarWidth = Math.min(420, Math.max(220, appSettings.sidebarWidth || 280));
  nativeTheme.themeSource = appSettings.theme === 'system' ? 'system' : appSettings.theme;
  const theme = effectiveTheme();

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

  if (process.env.BREEZE_DEBUG) win.webContents.openDevTools({ mode: 'bottom' });
  win.webContents.once('did-finish-load', () => {
    win.webContents.send('theme', effectiveTheme());
    win.webContents.send('sidebar', sidebarVisible);
    if (!sidebarVisible) startEdgePoll();
    win.webContents.send('settings', appSettings);
    layout();
    // On first run the onboarding overlay (DOM) must be visible — but a native
    // page view would paint over it. So defer the first tab until onboarding
    // finishes (see the 'onboarding-active' handler).
    if (appSettings.onboarded) createTab();
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
        {
          label: 'Passwords…',
          click: () => openInternalTab(PASSWORDS_URL),
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
          label: 'New Incognito Tab',
          accelerator: 'CmdOrCtrl+Shift+N',
          click: () => createTab(NEWTAB_URL, true, true),
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
          label: 'Picture in Picture',
          accelerator: 'Alt+CmdOrCtrl+P',
          click: () => {
            const wc = activeWC();
            if (wc) runPiP(wc, PIP_TOGGLE);
          },
        },
        {
          label: 'Toggle Dark Mode',
          accelerator: 'CmdOrCtrl+Shift+D',
          click: () => {
            const next = nativeTheme.themeSource === 'dark' ? 'light' : 'dark';
            applySetting('theme', next);
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
ipcMain.on('set-theme', (_e, theme) => applySetting('theme', theme));
ipcMain.on('install-update', () => {
  if (!updateDownloaded) return;
  const { autoUpdater } = require('electron-updater');
  autoUpdater.quitAndInstall();
});
ipcMain.handle('get-init', () => ({
  theme: effectiveTheme(),
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
ipcMain.on('reorder-pins', (_e, urls) => {
  const byUrl = new Map(pins.map((p) => [p.url, p]));
  const next = urls.map((u) => byUrl.get(u)).filter(Boolean);
  // keep any pins the renderer didn't know about
  for (const p of pins) if (!next.includes(p)) next.push(p);
  pins = next;
  saveSettings({ pins });
  pushState();
});
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

// tab groups
ipcMain.on('open-group-entry', (_e, { gid, eid }) => openGroupEntry(gid, eid));
ipcMain.on('rename-group', (_e, { gid, name }) => {
  const g = groups.find((x) => x.id === gid);
  if (g && name.trim()) {
    g.name = name.trim().slice(0, 40);
    saveGroups();
    pushState();
  }
});
ipcMain.on('group-entry-menu', (_e, { gid, eid }) => {
  const live = tabForEntry(eid);
  Menu.buildFromTemplate([
    { label: 'Open', click: () => openGroupEntry(gid, eid) },
    {
      label: 'Close',
      enabled: !!live,
      click: () => closeGroupEntry(eid), // tab closes, entry stays
    },
    { type: 'separator' },
    { label: 'Remove from Group', click: () => removeGroupEntry(gid, eid) },
  ]).popup({ window: win });
});
ipcMain.on('group-header-menu', (_e, gid) => {
  const g = groups.find((x) => x.id === gid);
  if (!g) return;
  Menu.buildFromTemplate([
    {
      label: 'Open All',
      click: () => g.entries.forEach((e) => openGroupEntry(gid, e.eid)),
    },
    {
      label: 'Close All',
      click: () => g.entries.forEach((e) => closeGroupEntry(e.eid)),
    },
    { type: 'separator' },
    {
      label: 'Rename…',
      click: () => win?.webContents.send('rename-group-start', gid),
    },
    { label: 'Delete Group', click: () => deleteGroup(gid) },
  ]).popup({ window: win });
});
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
  // clears the LIST only — files in ~/Downloads are never touched
  downloadList = downloadList.filter((d) => d.state === 'progressing');
  saveDownloads();
  broadcastDownloads();
});
ipcMain.on('set-setting', (_e, { key, value }) => {
  if (key in DEFAULT_SETTINGS) applySetting(key, value);
});
ipcMain.on('open-settings', () => openSettingsTab());

// Onboarding is a DOM overlay in the chrome, but native page views always
// paint ABOVE the DOM — so while onboarding shows we must detach the active
// page view, otherwise it hides the dialog and blanks the sidebar.
let onboardingActive = false;
ipcMain.on('onboarding-active', (_e, active) => {
  onboardingActive = active;
  if (active) {
    // hide any existing page view so the onboarding overlay is fully visible
    const t = tabs.get(activeTabId);
    if (t?.view) {
      try {
        win.contentView.removeChildView(t.view);
      } catch {}
    }
  } else {
    // onboarding finished — create the first tab now (or re-show the existing)
    if (tabOrder.length === 0) {
      createTab();
    } else {
      const t = tabs.get(activeTabId);
      if (t?.view) {
        win.contentView.addChildView(t.view);
        applyBounds();
      }
    }
  }
});

// Omnibox dropdown overlaps the native page view in top-bar mode. Native
// views always paint above DOM, so we push the active view down by the
// dropdown's height while it's open (only matters in top mode).
ipcMain.on('omnibox-overlay', (_e, h) => {
  const next = Math.max(0, Math.min(440, Math.round(h)));
  if (next === omniboxOffset) return;
  omniboxOffset = next;
  applyBounds();
});

// per-tab clear cache + storage, then hard reload (URL-bar button)
ipcMain.on('clear-tab-data', async () => {
  const wc = activeWC();
  if (!wc) return;
  try {
    const origin = new URL(wc.getURL()).origin;
    await wc.session.clearStorageData({ origin });
    await wc.session.clearCache();
    wc.reloadIgnoringCache();
  } catch {}
});

// per-site permission management (Settings → Privacy)
ipcMain.on('set-site-permission', (_e, { origin, permission, value }) => {
  const perms = appSettings.permissions || {};
  if (value === null) {
    if (perms[origin]) {
      delete perms[origin][permission];
      if (!Object.keys(perms[origin]).length) delete perms[origin];
    }
  } else {
    perms[origin] = { ...perms[origin], [permission]: !!value };
  }
  applySetting('permissions', perms);
});

// default browser
ipcMain.handle('is-default-browser', () => {
  try {
    return (
      app.isDefaultProtocolClient('http') && app.isDefaultProtocolClient('https')
    );
  } catch {
    return false;
  }
});
ipcMain.on('make-default-browser', () => {
  try {
    app.setAsDefaultProtocolClient('http');
    app.setAsDefaultProtocolClient('https');
  } catch {}
});

// ---------------------------------------------------------------------------
// App lifecycle
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Crash-safe storage: a "clean exit" marker lets us detect an unclean
// shutdown (crash / force-kill) on the next launch and silently rebuild the
// volatile caches that Chromium can leave half-written — WITHOUT touching
// cookies, IndexedDB data, or the user's logins. Users never see a problem.
// ---------------------------------------------------------------------------

const cleanExitMarker = () => path.join(app.getPath('userData'), '.clean-exit');

function healStorageIfUnclean() {
  let unclean = false;
  try {
    unclean = !fs.existsSync(cleanExitMarker());
  } catch {
    unclean = true;
  }
  if (unclean) {
    // only the disposable caches — these always rebuild, no data loss
    const dir = app.getPath('userData');
    for (const sub of [
      'Service Worker',
      'GPUCache',
      'Code Cache',
      'DawnCache',
      'DawnGraphiteCache',
      'DawnWebGPUCache',
      'blob_storage',
      'Shared Dictionary',
    ]) {
      try {
        fs.rmSync(path.join(dir, sub), { recursive: true, force: true });
      } catch {}
    }
  }
  // mark "running / dirty" until we exit cleanly
  try {
    fs.rmSync(cleanExitMarker(), { force: true });
  } catch {}
}

let didCleanShutdown = false;
function markCleanExit() {
  if (didCleanShutdown) return;
  didCleanShutdown = true;
  try {
    // force pending storage to disk so nothing is left half-written
    session.defaultSession.flushStorageData();
    session.defaultSession.cookies.flushStore().catch(() => {});
    if (incogSes) incogSes.flushStorageData();
  } catch {}
  try {
    fs.writeFileSync(cleanExitMarker(), String(Date.now()));
  } catch {}
}

app.whenReady().then(async () => {
  appSettings = { ...DEFAULT_SETTINGS, ...loadSettings() };
  healStorageIfUnclean();
  loadHistory();
  loadVault();
  loadDownloads();
  setupDownloads(session.defaultSession);
  setupPermissions(session.defaultSession);
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

// links opened from other apps when Breeze is the default browser
app.on('open-url', (e, url) => {
  e.preventDefault();
  if (app.isReady() && win) createTab(url, true);
  else app.whenReady().then(() => setTimeout(() => createTab(url, true), 500));
});

app.on('before-quit', () => {
  // persist everything, including any in-flight download (as interrupted)
  try {
    fs.writeFileSync(
      downloadsPath(),
      JSON.stringify(
        downloadList
          .map((d) => (d.state === 'progressing' ? { ...d, state: 'interrupted' } : d))
          .slice(0, 200)
      )
    );
  } catch {}
  // flush storage + drop the clean-exit marker so the next launch knows we
  // shut down properly (⌘Q, menu quit, window close — all routed here)
  markCleanExit();
});

// belt-and-suspenders: also flush on hard process signals
app.on('will-quit', markCleanExit);
process.on('exit', markCleanExit);
