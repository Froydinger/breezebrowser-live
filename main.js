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

// NOTE: we deliberately do NOT use `disable-frame-rate-limit`. It uncaps
// requestAnimationFrame, not just the compositor — rAF-driven libraries like
// Framer Motion then run their loops unbounded, pegging the main thread and
// causing jank/freezes across the web. The marginal high-refresh gain isn't
// worth breaking web animations. Removed in v2.3.12. Don't reintroduce it.

// Make sure OS dialogs and menus say "Breeze", never "Electron"
app.setName('Breeze');


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
let installingUpdate = false; // set before quitAndInstall so we don't hard-exit

const tabs = new Map(); // id -> { id, view, favicon }
let tabOrder = [];
let activeTabId = null;
let nextTabId = 1;

let sidebarVisible = true;
let sidebarPeek = false; // temporarily shown via edge-hover, not docked
let assistantVisible = false;
let aiFullscreen = false; // assistant expanded over the page (page context cut)
let layoutAnim = null;
let currentLeft = sidebarWidth;
let currentRight = 0;

let bookmarks = []; // [{ title, url }]

const NEWTAB_URL = `file://${path.join(__dirname, 'ui', 'newtab.html')}`;
// Reload-storm guard: stop a tab that loads its main frame this many times
// within the rolling window (redirect loop / runaway location.reload()).
const RELOAD_STORM_LIMIT = 10;
const RELOAD_STORM_WINDOW_MS = 6000;
const SETTINGS_URL = `file://${path.join(__dirname, 'ui', 'settings.html')}`;
const OVERLAY_URL = `file://${path.join(__dirname, 'ui', 'overlay.html')}`;

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
  onboarded: false, // first-run setup dialog shown
  webNotifications: true, // sites may show notifications (browser-wide)
  tabSleepHours: 4, // 2 | 4 | 6 | 0 (never)
  pinSize: 'large', // 'small' | 'medium' | 'large'
  neverSavePasswords: [], // origins the user said "never" for
  permissions: {},
  reminders: [], // [{ id, label, fireAt }] active reminders, re-armed on launch
  restoreTabs: 'ask', // 'ask' | 'always' | 'never' — reopen last session's tabs
  savedTabs: [], // URLs persisted from the previous session, restored on launch
  flattenFullscreenCorners: true, // square corners in fullscreen → hw video overlay
  lastSeenVersion: '', // version the user last saw the "what's new" popup for
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

function inSplitMode() {
  return !!(splitTabId && tabs.get(splitTabId) && splitTabId !== activeTabId);
}

function contentBounds(left, right) {
  const [w, h] = win.getContentSize();
  // In split view each pane gets its own in-view URL bar strip (in BOTH url-bar
  // modes), so we reserve that strip instead of the global top bar.
  const top =
    (inSplitMode()
      ? SPLIT_BAR_H
      : appSettings.urlBarPosition === 'top'
      ? TOPBAR_HEIGHT
      : 0) + omniboxOffset + (cornerPeek ? CORNER_PEEK_H : 0);
  return {
    x: Math.round(left) + CONTENT_PAD,
    y: CONTENT_PAD + top,
    width: Math.max(0, w - Math.round(left) - Math.round(right) - CONTENT_PAD * 2),
    height: Math.max(0, h - CONTENT_PAD * 2 - top),
  };
}

let splitTabId = null; // secondary tab shown beside the active one
let splitRatio = 0.5; // left pane width fraction
const SPLIT_DIVIDER = 14; // wide enough to grab (native views can't cover the gap)
const SPLIT_BAR_H = 44; // per-pane URL-bar strip height while in split view

function applyBounds() {
  if (!win) return;
  const b = contentBounds(currentLeft, currentRight);
  const a = tabs.get(activeTabId);
  const s = splitTabId ? tabs.get(splitTabId) : null;
  if (s && s.view && a && a.view && splitTabId !== activeTabId) {
    const leftW = Math.max(120, Math.round((b.width - SPLIT_DIVIDER) * splitRatio));
    const rightW = Math.max(120, b.width - SPLIT_DIVIDER - leftW);
    const rightX = b.x + leftW + SPLIT_DIVIDER;
    a.view.setBounds({ x: b.x, y: b.y, width: leftW, height: b.height });
    s.view.setBounds({ x: rightX, y: b.y, width: rightW, height: b.height });
    win.webContents.send('split-divider', {
      x: b.x + leftW,
      y: b.y,
      h: b.height,
      w: SPLIT_DIVIDER,
    });
    // Per-pane URL-bar strips sit in the reserved space directly above each view.
    win.webContents.send('split-bars', {
      barH: SPLIT_BAR_H,
      stripY: b.y - SPLIT_BAR_H,
      left: { tabId: activeTabId, x: b.x, w: leftW },
      right: { tabId: splitTabId, x: rightX, w: rightW },
    });
    raiseOverlay();
    return;
  }
  win.webContents.send('split-divider', null);
  win.webContents.send('split-bars', null);
  for (const { view } of tabs.values()) if (view) view.setBounds(b);
  raiseOverlay();
}

function enterSplit(id) {
  if (!tabs.has(id) || id === activeTabId) return;
  const t = tabs.get(id);
  wakeTab(t);
  splitTabId = id;
  if (t.view) win.contentView.addChildView(t.view);
  win?.webContents.send('split', true);
  applyBounds();
  pushState();
}

function exitSplit() {
  if (!splitTabId) return;
  const t = tabs.get(splitTabId);
  if (t?.view && splitTabId !== activeTabId) {
    try { win.contentView.removeChildView(t.view); } catch {}
  }
  splitTabId = null;
  win?.webContents.send('split', false);
  applyBounds();
  pushState();
}

function layout() {
  currentLeft = sidebarVisible || sidebarPeek ? sidebarWidth : 0;
  currentRight = assistantVisible ? ASSISTANT_WIDTH : 0;
  applyBounds();
}

// ---------------------------------------------------------------------------
// Notification overlay — a transparent WebContentsView pinned ABOVE the page
// views so essential toasts (downloads, updates) are always visible, with or
// without the sidebar. Sized to exactly its content so it never eats page
// clicks when empty. It's the ONLY chrome allowed to paint over the web view.
// ---------------------------------------------------------------------------
let overlayView = null;
let overlayVisible = false;

function createOverlay() {
  overlayView = new WebContentsView({
    webPreferences: {
      preload: path.join(__dirname, 'overlay-preload.js'),
      contextIsolation: true,
    },
  });
  try { overlayView.setBackgroundColor('#00000000'); } catch {}
  overlayView.setBounds({ x: 0, y: 0, width: 0, height: 0 });
  overlayView.webContents.loadURL(OVERLAY_URL);
  overlayView.webContents.once('did-finish-load', () => {
    overlayView.webContents.send('overlay-theme', effectiveTheme());
  });
  win.contentView.addChildView(overlayView);
}

function raiseOverlay() {
  // re-add to make it the top-most child again (page views added later would
  // otherwise cover it). Only bother while a toast is actually showing.
  if (overlayView && overlayVisible) {
    try { win.contentView.addChildView(overlayView); } catch {}
  }
}

function positionOverlay(w, h) {
  if (!overlayView || !win) return;
  overlayVisible = w > 0 && h > 0;
  if (!overlayVisible) {
    overlayView.setBounds({ x: 0, y: 0, width: 0, height: 0 });
    return;
  }
  // The overlay content has 26px of internal padding (shadow room), so offset
  // the view by -26 to keep the toast ~12px from the window's bottom-left.
  const [, ch] = win.getContentSize();
  overlayView.setBounds({ x: -14, y: ch - h + 14, width: w, height: h });
  raiseOverlay();
}

function showToast(toast) {
  if (!overlayView) return;
  overlayView.webContents.send('toast', toast);
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

// Corner peek: in fullscreen + sidebar-url mode there's no top bar to hold the
// Breeze mark, and a DOM button can't paint over the native page view — so we
// poll the cursor (only while fullscreen, never perpetually) and, when it's in
// the top-right corner, inset the page a little to reveal the button.
let cornerPeek = false;
let cornerPoll = null;
const CORNER_PEEK_H = 46;

function setCornerPeek(v) {
  if (cornerPeek === v) return;
  cornerPeek = v;
  win?.webContents.send('corner-peek', v);
  applyBounds();
}

function startCornerPoll() {
  if (cornerPoll) return;
  cornerPoll = setInterval(() => {
    if (!win || win.isDestroyed() || !win.isFocused()) return;
    // only relevant in fullscreen + sidebar url mode
    if (!win.isFullScreen() || appSettings.urlBarPosition === 'top') {
      setCornerPeek(false);
      return;
    }
    try {
      const cur = screen.getCursorScreenPoint();
      const b = win.getBounds();
      const inCorner =
        cur.y >= b.y && cur.y <= b.y + 60 &&
        cur.x >= b.x + b.width - 90 && cur.x <= b.x + b.width;
      setCornerPeek(inCorner);
    } catch {}
  }, 200);
}

function stopCornerPoll() {
  if (cornerPoll) {
    clearInterval(cornerPoll);
    cornerPoll = null;
  }
  setCornerPeek(false);
}

function notifyAIPanel(open) {
  // tell the active tab's page whether to track text selections
  const t = tabs.get(activeTabId);
  try {
    t?.view?.webContents.send('ai-panel', open);
  } catch {}
}

function setAssistant(show) {
  assistantVisible = show;
  win?.webContents.send('assistant', show);
  notifyAIPanel(show);
  animateLayout();
  if (show) {
    clearTimeout(ai.idleTimer);
    ensureAI(); // kick off model download/load in the background
    // Move keyboard focus off the native page view to the chrome so the AI
    // input can take it — otherwise typing still goes to the page (e.g. a new
    // tab). The renderer focuses #ai-input once it has focus.
    try { win?.webContents.focus(); } catch {}
  } else {
    if (aiFullscreen) setAIFullscreen(false); // closing the panel exits fullscreen
    scheduleAIIdleUnload(); // free the model after the panel's been closed a while
  }
}

// Fullscreen assistant: the chat DOM expands over the whole window. Native page
// views always paint above the DOM, so we DETACH them (like onboarding does) —
// which also isolates the chat: read_current_page is gated off while fullscreen.
// Docking reattaches the active (and split) views and restores the layout.
function setAIFullscreen(on) {
  on = !!on;
  if (on === aiFullscreen) {
    if (on) win?.webContents.send('ai-fullscreen', true);
    return;
  }
  const a = tabs.get(activeTabId);
  const s = splitTabId ? tabs.get(splitTabId) : null;
  if (on) {
    if (!assistantVisible) setAssistant(true);
    aiFullscreen = true;
    for (const v of [a, s]) {
      if (v?.view) { try { win.contentView.removeChildView(v.view); } catch {} }
    }
    try { win?.webContents.focus(); } catch {}
  } else {
    aiFullscreen = false;
    for (const v of [a, s]) {
      if (v?.view) { try { win.contentView.addChildView(v.view); } catch {} }
    }
    applyBounds();
    raiseOverlay();
  }
  win?.webContents.send('ai-fullscreen', on);
}

// Any navigation while fullscreen docks the chat so the page can show. Called
// at the top of activateTab / loadInTab; reattaches the active view itself.
function autoDockAI() {
  if (aiFullscreen) setAIFullscreen(false);
}

// ⌘E / menu toggle. On the new-tab page there's no point opening the sidebar
// assistant — the new tab IS the assistant — so just focus its input instead.
function toggleAssistant() {
  const t = tabs.get(activeTabId);
  const onNewTab = t && tabURL(t).startsWith(NEWTAB_URL);
  if (!assistantVisible && onNewTab) {
    try { t.view?.webContents.focus(); } catch {}
    try { t.view?.webContents.send('focus-newtab-input'); } catch {}
    return;
  }
  setAssistant(!assistantVisible);
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

function tabURL(t) {
  if (t.sleeping) return t.saved?.url || '';
  return t.view ? t.view.webContents.getURL() : '';
}

// Collect the URLs of the current session's restorable tabs, in tab order.
// Skips incognito tabs (never persisted) and internal file:// pages (new-tab,
// settings, etc. — nothing worth reopening). Used for tab restore on launch.
function captureSessionTabs() {
  const urls = [];
  for (const id of tabOrder) {
    const t = tabs.get(id);
    if (!t || t.incognito) continue;
    const u = tabURL(t);
    if (!u || u.startsWith('file://') || u.startsWith('about:')) continue;
    urls.push(u);
  }
  return urls;
}

// Open the previous session's saved tabs (if any), else a single new tab.
// Consumed once: the saved list is cleared after restoring, then re-saved on
// the next quit — so a crash still restores, but a clean session won't loop.
function restoreSessionOrNewTab() {
  const saved = Array.isArray(appSettings.savedTabs) ? appSettings.savedTabs : [];
  if (!saved.length) {
    createTab();
    return;
  }
  saved.forEach((url, i) => createTab(url, i === 0));
  saveSettings({ savedTabs: [] });
}

// Normalize an origin to a single canonical key. Chromium's permission CHECK
// handler hands us a trailing-slash form ("https://x.com/") while the REQUEST
// handler and the URL-bar use new URL().origin ("https://x.com"). Storing both
// caused split-brain (check said granted, request said denied → enable hung).
function originKey(o) {
  try { return new URL(o).origin; } catch { return String(o || '').replace(/\/+$/, ''); }
}
// Notifications per-origin state: true | false | undefined (undecided).
function notifState(origin) {
  return (appSettings.permissions || {})[originKey(origin)]?.notifications;
}
// Effective allow used by the URL-bar bell and sync checks.
function notifAllowed(origin) {
  const saved = notifState(origin);
  if (saved !== undefined) return saved;
  return appSettings.webNotifications !== false;
}
// Remember which origins actually use notifications, so the URL-bar bell only
// appears for sites that have asked — no clutter on sites that never notify.
function markNotifSite(origin) {
  if (!origin) return;
  origin = originKey(origin);
  const m = appSettings.notifSites || {};
  if (m[origin]) return;
  m[origin] = true;
  applySetting('notifSites', m);
  pushState();
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
      perfMode: !!t.perfMode,
    };
  }
  const wc = t.view.webContents;
  const url = wc.getURL();
  const isInternal = url.startsWith('file://');
  let origin = null;
  try { if (!isInternal) origin = new URL(url).origin; } catch {}
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
    perfMode: !!t.perfMode,
    // URL-bar notification bell: shown only for sites that use notifications
    notifSite: !!(origin && (appSettings.notifSites || {})[origin]),
    notifOn: origin ? notifAllowed(origin) : false,
  };
}

// Coalesced: busy SPAs fire did-navigate-in-page / title / loading events
// many times a second, and each push serializes all state, polls audio on
// every tab, and forces the chrome renderer to redraw the sidebar. Batching
// to one push per 80ms keeps main + chrome renderer idle-cheap.
let pushStateTimer = null;

function pushState() {
  if (pushStateTimer) return;
  pushStateTimer = setTimeout(() => {
    pushStateTimer = null;
    pushStateNow();
  }, 80);
}

function pushStateNow() {
  if (!win) return;
  syncGroupEntries();
  try {
    updateNowPlaying();
  } catch {}
  win.webContents.send('state', {
    tabs: tabOrder.map((id) => tabState(tabs.get(id))),
    activeTabId,
    splitTabId,
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
  t.preloadInternal = isInternal; // which preload this view carries
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

  // Rounded corners cost a little GPU during video playback (blocks the
  // hardware video overlay), but the idle burn was elsewhere (perpetual
  // animations + pushState storms) — keeping the look is worth it.
  try {
    view.setBorderRadius(t.perfMode ? 0 : 12);
  } catch {} // older Electron: no rounded corners, no problem
  // Paint the view's backing the theme color so internal pages (new tab) don't
  // flash white for a frame before their HTML paints.
  if (isInternal) {
    try { view.setBackgroundColor(effectiveTheme() === 'dark' ? '#16161a' : '#f2f0ed'); } catch {}
  }

  const wc = view.webContents;
  // Reapply Performance Mode if this tab had it on (e.g. after waking).
  if (t.perfMode) { try { wc.setBackgroundThrottling(false); } catch {} }
  wc.on('focus', () => { lastWCFocusAt = Date.now(); });
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
    // Flatten corners in fullscreen so the compositor can use the zero-copy
    // hardware video overlay (rounded corners block it) — lower GPU/power and
    // a touch less latency for cloud gaming & fullscreen video. Corners are
    // off-screen here anyway, so there's no visual cost. Opt-out in Settings.
    if (appSettings.flattenFullscreenCorners !== false) {
      try { view.setBorderRadius(0); } catch {}
    }
  });
  wc.on('leave-html-full-screen', () => {
    applyBounds();
    // restore the rounded look — unless Performance Mode wants square corners
    try { view.setBorderRadius(t.perfMode ? 0 : 12); } catch {}
  });
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
  wc.on('did-fail-load', (_e, errorCode, desc, _url, isMainFrame) => {
    if (!isMainFrame) return;
    if (errorCode === -3) return; // ERR_ABORTED (user navigated away)
    t.lastError = { code: errorCode, desc }; // remembered for the storm page
    if (t.didAutoRetry) return;
    t.didAutoRetry = true;
    setTimeout(() => {
      if (t.view && !t.view.webContents.isDestroyed()) t.view.webContents.reload();
    }, 400);
  });
  wc.on('did-finish-load', () => {
    t.didAutoRetry = false; // reset for the next navigation
    // a freshly loaded page has a fresh preload — restore selection tracking
    if (assistantVisible && t.id === activeTabId) {
      try { wc.send('ai-panel', true); } catch {}
    }
  });

  // Reload-storm guard: a redirect loop or runaway location.reload() can pin a
  // tab reloading forever. Count main-frame loads in a rolling window; once it
  // crosses the threshold, stop the page and show an error (with the last
  // network error, if any). An explicit user navigation resets the budget.
  t.loadTimes = [];
  t.stormStopped = false;
  t.lastError = null;
  t.lastNavUrl = '';
  wc.on('did-start-navigation', (_e, navUrl, _inPlace, isMain) => {
    if (isMain) t.lastNavUrl = navUrl;
  });
  wc.on('will-navigate', () => { t.loadTimes = []; t.stormStopped = false; });
  wc.on('did-start-loading', () => {
    const now = Date.now();
    t.loadTimes = (t.loadTimes || []).filter((x) => now - x < RELOAD_STORM_WINDOW_MS);
    t.loadTimes.push(now);
    if (!t.stormStopped && t.loadTimes.length >= RELOAD_STORM_LIMIT) {
      t.stormStopped = true;
      try { wc.stop(); } catch {}
      showReloadStormPage(t);
    }
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
// PiP routing. Electron gives us no direct signal for the PiP window's
// "back to tab" button, but the click focuses our browser window (a wc
// 'focus' fires) right before the owner page reports leaving PiP — while
// the X close emits no focus at all. Track both and route accordingly.
let lastWCFocusAt = 0;
ipcMain.on('pip-state', (e, inPiP) => {
  for (const t of tabs.values()) {
    if (t.view && t.view.webContents === e.sender) {
      const was = t.inPiP;
      t.inPiP = inPiP === true;
      if (
        was &&
        !t.inPiP &&
        t.id !== activeTabId &&
        Date.now() - lastWCFocusAt < 600
      ) {
        activateTab(t.id);
        if (win) {
          if (win.isMinimized()) win.restore();
          win.show();
          win.focus();
        }
      }
      break;
    }
  }
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
    inPiP: false,
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

// Performance Mode (the 🚀 toggle): per-tab wins for cloud gaming / streaming.
// 1) flatten corners → restores the zero-copy hardware video overlay (the real
//    smoothness win), and 2) disable background throttling so the tab keeps
//    running full-tilt even when it's not focused. Scoped to THIS tab only —
//    no global frame-rate uncap (that broke Framer Motion + drained battery).
function setPerfMode(id, on) {
  const t = tabs.get(id);
  if (!t) return;
  t.perfMode = !!on;
  const wc = t.view?.webContents;
  if (wc) {
    try { t.view.setBorderRadius(on ? 0 : 12); } catch {}
    try { wc.setBackgroundThrottling(!on); } catch {}
  }
  pushState();
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
  autoDockAI(); // a tab switch / new page docks a fullscreen chat
  // clicking the split partner just focuses it; clicking any other tab while
  // split is on exits split first (keeps the layout simple & robust)
  if (splitTabId) {
    if (id === splitTabId) {
      t.view?.webContents.focus();
      return;
    }
    if (id !== activeTabId) exitSplit();
  }
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
  if (prev?.view) {
    try { prev.view.webContents.send('ai-panel', false); } catch {}
  }
  if (assistantVisible) notifyAIPanel(true); // new tab should track selections
  pushState();
}

function closeTab(id) {
  const t = tabs.get(id);
  if (!t) return;
  if (id === splitTabId || (id === activeTabId && splitTabId)) exitSplit();
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

function openSettingsTab(section) {
  const hash = section ? `#${section}` : '';
  for (const id of tabOrder) {
    const t = tabs.get(id);
    if ((tabURL(t) || '').startsWith(SETTINGS_URL)) {
      activateTab(id);
      if (section) t.view?.webContents.loadURL(SETTINGS_URL + hash);
      return;
    }
  }
  createTab(SETTINGS_URL + hash, true);
}

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

// Debounced: syncGroupEntries calls this whenever a grouped tab's title or
// URL changes, and saveSettings is a synchronous disk read+write.
let saveGroupsTimer = null;
function saveGroups() {
  if (saveGroupsTimer) return;
  saveGroupsTimer = setTimeout(() => {
    saveGroupsTimer = null;
    saveSettings({ groups });
  }, 500);
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
    splitTabId
      ? { label: 'Exit Split View', click: () => exitSplit() }
      : {
          label: 'Open in Split View',
          enabled: id !== activeTabId && tabs.size > 1,
          click: () => enterSplit(id),
        },
    { type: 'separator' },
    {
      label: '🚀 Performance Mode',
      type: 'checkbox',
      checked: !!t.perfMode,
      enabled: isWeb,
      click: () => setPerfMode(id, !t.perfMode),
    },
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

// Proactive autofill: a page-preload asks if we have a login for its origin.
// We answer only to the tab's own URL, never incognito, and hand back just
// what's needed to fill the form (stays in the isolated preload world).
ipcMain.handle('cred-check', (e) => {
  if (e.sender.session !== session.defaultSession) return [];
  const creds = credsForOrigin(e.sender.getURL());
  return creds.map((c) => ({ username: c.username || '', password: c.password }));
});

// Offer to save credentials captured from a login (form submit OR the JS-login
// signals page-preload now sends). Those signals can fire several times for one
// login, so we dedupe recent identical captures and only show one prompt.
let credPromptOpen = false;
let lastCredSig = '';
let lastCredAt = 0;

ipcMain.on('cred-captured', async (e, { origin, username, password }) => {
  if (credPromptOpen || !origin || !password) return;
  // never prompt for incognito tabs
  if (e.sender.session !== session.defaultSession) return;
  if ((appSettings.neverSavePasswords || []).includes(origin)) return;
  // collapse the burst of triggers (click + Enter + route change + pagehide)
  const sig = `${origin} ${username} ${password}`;
  if (sig === lastCredSig && Date.now() - lastCredAt < 15000) return;
  lastCredSig = sig;
  lastCredAt = Date.now();
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
    // visual feedback — sites/images often save silently otherwise
    showToast({ id, kind: 'download', text: `Download started · ${entry.filename}`, action: 'open-downloads' });

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
      if (state === 'completed') {
        showToast({ id, kind: 'download', text: `Downloaded · ${entry.filename}`, action: 'open-downloads' });
      } else if (state === 'interrupted') {
        showToast({ id, kind: 'download', text: `Download failed · ${entry.filename}` });
      }
      // 'cancelled' → no toast, the user did it on purpose
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
  // Notifications: the sync CHECK reports the current effective state (a site
  // reads Notification.permission first). The async REQUEST is where we show a
  // Chrome-style Allow/Block prompt the first time a site actually asks, then
  // remember the per-site choice. The global toggle in Settings is a master
  // kill-switch. notifAllowed()/originKey() live at module scope so the
  // URL-bar bell (tabState) reads exactly the same state.

  // synchronous probes (e.g. WebAuthn availability checks, Notification.permission)
  ses.setPermissionCheckHandler((_wc, permission, origin) => {
    if (autoAllow.has(permission)) return true;
    if (permission === 'notifications') {
      if (ses === session.defaultSession) markNotifSite(origin);
      return notifAllowed(origin);
    }
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
    if (permission === 'notifications') {
      if (ses === session.defaultSession) markNotifSite(origin);
      // master kill-switch off → deny without nagging
      if (appSettings.webNotifications === false) return callback(false);
      // already decided for this site → honor it silently
      const decided = notifState(origin);
      if (decided !== undefined) return callback(decided);
      // first real request → ask, Chrome-style, and remember the choice
      const { response } = await dialog.showMessageBox(win, {
        type: 'question',
        message: `Allow ${origin.replace(/^https?:\/\//, '')} to send you notifications?`,
        detail: 'You can change this anytime with the bell in the address bar.',
        buttons: ['Allow', 'Block'],
        defaultId: 0,
        cancelId: 1,
      });
      const allow = response === 0;
      const perms = appSettings.permissions || {};
      perms[origin] = { ...perms[origin], notifications: allow };
      applySetting('permissions', perms);
      pushState();
      return callback(allow);
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
// AI web access is agentic now (see agenticWebSearch): the assistant drives the
// real browser — opening the user's default search engine in a tab and reading
// it — so there's no third-party API, and no key to bundle or manage.
// ---------------------------------------------------------------------------
// Local AI assistant (llama.cpp via node-llama-cpp, Metal-accelerated)
// ---------------------------------------------------------------------------

// Qwen2.5 3B Instruct — same ~2GB footprint as Llama 3.2 3B but markedly better
// at function-calling, which is what powers reminders + agentic web search.
// Stays 100% local (downloaded once, runs on-device via Metal).
const MODEL_URI =
  'hf:bartowski/Qwen2.5-7B-Instruct-GGUF/Qwen2.5-7B-Instruct-Q4_K_M.gguf';
const MODEL_LABEL = 'Qwen2.5 7B';

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

// Pre-download the model FILE at launch (not loaded into RAM) so the user
// never waits on a multi-GB download when they first open the assistant. The
// file is cached, so this is a no-op on later launches. ensureAI awaits this
// before its own download so the two never race into a double download.
let modelPrefetch = null;
function prefetchModel() {
  if (ai.ready || ai.loading || modelPrefetch) return modelPrefetch;
  modelPrefetch = (async () => {
    try {
      const { resolveModelFile } = await import('node-llama-cpp');
      await resolveModelFile(MODEL_URI, {
        directory: path.join(app.getPath('userData'), 'models'),
        onProgress: ({ downloadedSize, totalSize }) =>
          sendAI({ state: 'downloading', progress: totalSize ? downloadedSize / totalSize : 0 }),
      });
    } catch { /* ensureAI will surface any real error when the panel opens */ }
  })();
  return modelPrefetch;
}

async function ensureAI() {
  if (ai.ready || ai.loading) return ai.ready;
  ai.loading = true;
  try {
    const { getLlama, LlamaChatSession, resolveModelFile, defineChatSessionFunction } = await import(
      'node-llama-cpp'
    );
    ai.LlamaChatSession = LlamaChatSession;
    ai.defineChatSessionFunction = defineChatSessionFunction;

    sendAI({ state: 'downloading', progress: 0 });
    if (modelPrefetch) { try { await modelPrefetch; } catch {} } // reuse the launch download
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
    "— but don't ramble or pad. Everything you run does so " +
    "locally on the user's Mac, and you're quietly proud of that — their data never leaves.\n\n" +
    'You have tools. Use them ONLY when they actually fit the question — do not assume ' +
    'every question is about the current web page:\n' +
    '- web_search: call it when the user asks about current events, facts you are unsure ' +
    'of, or anything that benefits from up-to-date info. It opens a real search in a tab ' +
    'and reads the results. Cite the source links you get back as markdown [title](url). ' +
    "Search with the user's words EXACTLY — never tack on a year or date (do NOT turn " +
    '"pizza in chicago" into "pizza in chicago 2023"); your training year is not today.\n' +
    "- read_current_page: call it ONLY when the user's question is clearly about the page " +
    'they are looking at (e.g. "summarize this", "what does this say"). If the question is ' +
    'unrelated to the page, do NOT call it — just answer normally.\n' +
    '- open_page: call it when the user names a site or asks you to go to / open / visit / pull ' +
    'up a specific address (e.g. "go to winthenight.org", "open example.com and summarize it"). ' +
    'It opens the page and returns its text. If they asked you to then summarize or act on it, ' +
    'do that with the text you get back — in ONE flow, without asking "which page?".\n' +
    '- set_reminder: call it when the user asks to be reminded of something at a later time. ' +
    'Convert their timing into minutes from now.\n' +
    'If a question is just general knowledge or chit-chat, answer directly with no tools.\n\n' +
    'CRITICAL: when you decide to use a tool, call it IMMEDIATELY and silently. Do NOT ' +
    'write a sentence like "Let me find that" or "I\'ll search for you" and then stop — ' +
    'that leaves the user hanging. Either call the tool right away (the user already sees a ' +
    'chip showing you\'re searching) or answer directly. Never announce a search instead of ' +
    'doing it.\n\n' +
    `Today's date is ${new Date().toLocaleDateString('en-US', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' })}. ` +
    'Whenever the date or anything time-sensitive matters, use THIS date — never a date from ' +
    'your training. If you genuinely need to know "today", it is right here.\n\n' +
    'If a request is missing information you\'d need to answer well — most often a LOCATION ' +
    '(e.g. "where can I get pizza", "what\'s the weather", "things to do near me") but also ' +
    'any other essential detail — ask a short, friendly follow-up question FIRST instead of ' +
    'guessing or searching with a made-up value. You are allowed and encouraged to ask ' +
    'follow-ups. As SOON as the user gives you the missing detail (e.g. they reply ' +
    '"chicago"), call web_search right away with the now-complete query — do NOT answer ' +
    'from memory.\n\n' +
    'NEVER fabricate facts, places, businesses, prices, or links. If you did not get them ' +
    'from a web_search result or the current page, you do not know them — say so. It is ' +
    'much better to admit you could not find something than to invent it.';
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

// --- Reminders: persisted, re-armed on launch, fired as native notifications -

const reminderTimers = new Map(); // id -> timeout handle

function getReminders() {
  return Array.isArray(appSettings.reminders) ? appSettings.reminders : [];
}

function saveReminders(list) {
  applySetting('reminders', list);
  win?.webContents.send('reminders-changed', list);
  pushState();
}

function fireReminder(id, missed) {
  const r = getReminders().find((x) => x.id === id);
  removeReminder(id, true);
  if (!r) return;
  // Persistent in-app toast so they can't miss it while using Breeze...
  showToast({
    kind: 'reminder',
    text: (missed ? 'Missed reminder · ' : 'Reminder · ') + r.label,
    persist: true,
  });
  // ...plus a native notification for when Breeze isn't in focus.
  try {
    const n = new Notification({
      title: missed ? 'Breeze reminder (missed)' : 'Breeze reminder',
      body: r.label,
      silent: true, // the overlay toast plays the chime; avoid a double sound
    });
    n.on('click', () => { win?.show(); win?.focus(); });
    n.show();
  } catch {}
}

function armReminder(r) {
  clearTimeout(reminderTimers.get(r.id));
  const delay = Math.max(0, r.fireAt - Date.now());
  // setTimeout caps at ~24.8 days; clamp and it'll re-arm on next launch anyway
  reminderTimers.set(r.id, setTimeout(() => fireReminder(r.id), Math.min(delay, 2 ** 31 - 1)));
}

// add a reminder N ms from now; returns the stored record
function addReminder(label, ms) {
  const r = { id: `r${Date.now()}${Math.floor(Math.random() * 1000)}`, label: label || 'Reminder', fireAt: Date.now() + ms };
  const list = [...getReminders(), r];
  saveReminders(list);
  armReminder(r);
  return r;
}

function removeReminder(id, skipNotify) {
  clearTimeout(reminderTimers.get(id));
  reminderTimers.delete(id);
  const list = getReminders().filter((x) => x.id !== id);
  saveReminders(list);
  return list;
}

// On launch: re-arm the still-future ones, and FIRE any that came due while
// Breeze was closed so the user is caught up (a short delay lets the window +
// overlay finish loading first).
function initReminders() {
  const now = Date.now();
  const all = getReminders();
  const live = all.filter((r) => r.fireAt > now);
  const missed = all.filter((r) => r.fireAt <= now);
  // keep only live in storage; missed get fired then dropped
  saveReminders(live);
  for (const r of live) armReminder(r);
  if (missed.length) {
    setTimeout(() => {
      for (const r of missed) {
        try {
          showToast({ kind: 'reminder', text: 'Missed reminder · ' + r.label, persist: true });
          const n = new Notification({ title: 'Breeze reminder (missed)', body: r.label, silent: true });
          n.on('click', () => { win?.show(); win?.focus(); });
          n.show();
        } catch {}
      }
    }, 3500);
  }
}

function humanizeMs(ms) {
  const m = Math.round(ms / 60000);
  if (m < 1) return 'less than a minute';
  if (m < 60) return `${m} minute${m > 1 ? 's' : ''}`;
  const h = Math.round(m / 60);
  if (h < 48) return `${h} hour${h > 1 ? 's' : ''}`;
  const d = Math.round(h / 24);
  return `${d} day${d > 1 ? 's' : ''}`;
}

// --- Agentic web search: drive the REAL browser instead of an API ---------
// Opens the user's default search engine in a new (visible) tab, waits for it
// to render, reads the results, then follows the top result and reads that too.
// No third-party API key — it's just the browser doing what it already does.

function aiToolChip(label) {
  win?.webContents.send('ai-tool', { kind: 'web', label });
}

function waitForLoad(wc, timeout = 12000) {
  return new Promise((resolve) => {
    let done = false;
    const finish = () => { if (done) return; done = true; cleanup(); resolve(); };
    const cleanup = () => {
      clearTimeout(to);
      try { wc.removeListener('did-finish-load', finish); } catch {}
      try { wc.removeListener('did-stop-loading', finish); } catch {}
    };
    const to = setTimeout(finish, timeout);
    wc.once('did-finish-load', finish);
    wc.once('did-stop-loading', finish);
  });
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

// Pull the top organic result links off a search-results page, skipping the
// engine's own domain and obvious non-result chrome.
const LINK_EXTRACT = `(() => {
  const eng = location.hostname.replace(/^www\\./, '');
  const seen = new Set();
  const out = [];
  for (const a of document.querySelectorAll('a[href^="http"]')) {
    let u; try { u = new URL(a.href); } catch { continue; }
    const h = u.hostname.replace(/^www\\./, '');
    if (h === eng || h.endsWith('google.com') || h.endsWith('bing.com') ||
        h.endsWith('duckduckgo.com') || h.endsWith('brave.com') ||
        h.endsWith('microsoft.com') || h.endsWith('youtube.com/redirect') ||
        u.pathname.length < 2) continue;
    const key = u.origin + u.pathname;
    if (seen.has(key)) continue;
    seen.add(key);
    const text = (a.innerText || '').trim();
    if (text.length < 4) continue;
    out.push({ url: a.href, title: text.slice(0, 120) });
    if (out.length >= 6) break;
  }
  return out;
})()`;

async function extractFrom(wc) {
  try {
    const text = await wc.executeJavaScript(EXTRACT_CONTEXT, true);
    return String(text || '').slice(0, 6000);
  } catch { return ''; }
}

async function agenticWebSearch(query) {
  const engineUrl = ENGINES[appSettings.searchEngine] || ENGINES.google;
  const engineName = (appSettings.searchEngine || 'google')
    .replace(/^./, (c) => c.toUpperCase());
  const url = engineUrl.replace('%s', encodeURIComponent(query));

  sendAI({ state: 'searching' });
  aiToolChip(`Searching ${engineName} for "${query.slice(0, 60)}"`);
  // persistent, clickable record of this agentic search in the chat transcript
  win?.webContents.send('ai-search', { query, url, engine: engineName });

  // open a real, visible tab so the user watches it happen
  const id = createTab(url, true);
  const t = tabs.get(id);
  if (!t || !t.view) return 'Web search failed to open a tab.';
  const wc = t.view.webContents;
  await waitForLoad(wc);

  // Read the results page ITSELF — don't open any single result. Modern search
  // engines (esp. the AI ones) STREAM their synthesized answer in over a few
  // seconds AFTER load, so we can't read immediately or we get a near-empty
  // page (and the model then hallucinates). Wait for the page text to stop
  // growing (settle) with a ~3s floor and ~8s ceiling.
  aiToolChip(`Reading the ${engineName} results`);
  await delay(1500);
  let serp = '';
  const started = Date.now();
  while (Date.now() - started < 7000) {
    const t2 = await extractFrom(wc);
    // settled: a non-trivial page that stopped growing meaningfully
    if (t2.length > 200 && t2.length - serp.length < 40) { serp = t2; break; }
    if (t2.length > serp.length) serp = t2;
    await delay(800);
  }

  let links = [];
  try { links = await wc.executeJavaScript(LINK_EXTRACT, true); } catch {}

  // Guard against the page never producing readable content — better to admit
  // it than to invent results.
  if (serp.trim().length < 120 && !links.length) {
    return (
      `The ${engineName} results page didn't return readable content in time. ` +
      `Tell the user you couldn't read the search results this time and suggest ` +
      `they try again — do NOT make up an answer or list places from memory.`
    );
  }

  const sourceList = links
    .slice(0, 6)
    .map((l, i) => `[${i + 1}] ${l.title}\n${l.url}`)
    .join('\n');

  return (
    `Live web results for "${query}", read straight from the ${engineName} ` +
    `results page. Base your answer ONLY on what's here, summarize across all of ` +
    `it, and cite the relevant links as markdown [title](url). If something isn't ` +
    `in these results, say you don't know — do NOT invent facts or list places ` +
    `from memory.\n\n` +
    `RESULTS PAGE CONTENT:\n${serp.slice(0, 6000)}\n\n` +
    `LINKS ON THE PAGE (for citing):\n${sourceList || '(none found)'}`
  );
}

ipcMain.on('ai-ask', async (_e, { text, selection }) => {
  if (ai.generating) return;

  if (!(await ensureAI())) return;
  ai.generating = true;

  let prompt = text;

  // selected page text the user highlighted — make it the focus
  if (selection && selection.trim()) {
    win?.webContents.send('ai-tool', { kind: 'selection', label: 'Using your selected text' });
    prompt = `[The user highlighted this text on the page]\n"${selection.trim().slice(0, 2000)}"\n\n${prompt}`;
  }

  // Proactively read the current page when the question clearly refers to it
  // ("this", "this page", "summarize", "tl;dr"…) so the model never has to ask
  // "which page?" or wait to be told to look. Only when a readable page exists.
  const refersToPage =
    /\b(this|that|the page|this page|here|above|below|the (article|site|video|story|post)|summar(y|ize|ise)|tl;?dr|recap|explain (this|it)|read (this|it)|what(?:'s| is) (this|it))\b/i.test(text);
  if (refersToPage && !(selection && selection.trim())) {
    const ctx = await getPageContext();
    if (ctx) {
      win?.webContents.send('ai-tool', { kind: 'page', label: `Reading "${ctx.title}"` });
      prompt =
        `[Current page: "${ctx.title}" — ${ctx.url}]\n[Page content]\n${ctx.text}\n` +
        `[End page content]\n\n${prompt}`;
      ai.lastCtxUrl = ctx.url;
    }
  }

  sendAI({ state: 'generating' });

  // Per-turn tool-call budget. Small local models can loop calling web_search
  // forever (each ~8s) and blow past the watchdog without ever answering — so
  // we cap calls and, once spent, tell the model to answer with what it has.
  let searchCount = 0;
  let readCount = 0;
  let openCount = 0;
  const MAX_SEARCHES = 3;
  const MAX_READS = 2;
  const MAX_OPENS = 2;

  // Tools the model can call. node-llama-cpp runs the handler, feeds the result
  // back, and continues — so the model decides WHEN the page / web is relevant.
  const def = ai.defineChatSessionFunction;
  const functions = {
    web_search: def({
      description:
        'Search the live web and read the results page. Use for current events, ' +
        'recent facts, prices, local info, or anything you are unsure about. ' +
        'Returns the full results-page content plus the links found on it to cite.',
      params: {
        type: 'object',
        properties: { query: { type: 'string', description: 'the search query' } },
        required: ['query'],
      },
      handler: async ({ query }) => {
        if (++searchCount > MAX_SEARCHES) {
          return 'You have already searched enough this turn. Do NOT search again — answer the user now with what you already have.';
        }
        try { return await agenticWebSearch(String(query || text)); }
        catch (e) { return `Web search failed: ${e.message}`; }
        finally { sendAI({ state: 'generating' }); }
      },
    }),
    read_current_page: def({
      description:
        "Read the text of the web page the user is currently looking at. Use ONLY " +
        "when the user's question is about that page (e.g. summarize/explain this).",
      params: { type: 'object', properties: {} },
      handler: async () => {
        if (++readCount > MAX_READS) return 'You already read the page. Answer now with what you have.';
        if (aiFullscreen) return 'No page is open to read (the chat is fullscreen). If the user named a site, use open_page first.';
        const ctx = await getPageContext();
        if (!ctx) return 'There is no readable web page open right now. If the user named a site, use open_page to open it first.';
        win?.webContents.send('ai-tool', { kind: 'page', label: `Reading "${ctx.title}"` });
        return `Page: "${ctx.title}" — ${ctx.url}\n\n${ctx.text}`;
      },
    }),
    open_page: def({
      description:
        'Open a web page in the browser when the user asks you to go to / open / visit / pull up a ' +
        'specific site or URL (e.g. "go to winthenight.org", "open example.com and summarize it"). ' +
        'Opens it in a tab, waits for it to load, and returns its text so you can act on it.',
      params: {
        type: 'object',
        properties: { url: { type: 'string', description: 'the URL or domain to open, e.g. example.com or https://example.com/page' } },
        required: ['url'],
      },
      handler: async ({ url }) => {
        if (++openCount > MAX_OPENS) return 'You already opened a page this turn. Read or answer with what you have.';
        const target = toNavigableURL(String(url || ''));
        if (!target) return `"${url}" doesn't look like a valid web address.`;
        win?.webContents.send('ai-tool', { kind: 'page', label: `Opening ${String(url).replace(/^https?:\/\//, '')}` });
        const id = createTab(target, true); // opens + activates (docks a fullscreen chat)
        const t = tabs.get(id);
        if (!t?.view) return 'Failed to open the page.';
        try { await waitForLoad(t.view.webContents); } catch {}
        await delay(600);
        const ctx = await getPageContext();
        if (ctx && ctx.text) {
          return `Opened "${ctx.title}" — ${ctx.url}\n\nPage content:\n${ctx.text.slice(0, 6000)}`;
        }
        return `Opened ${target}, but couldn't read its text. Tell the user it's open.`;
      },
    }),
    set_reminder: def({
      description:
        'Set a reminder that fires a notification later. Convert the user\'s ' +
        'requested time into whole minutes from now.',
      params: {
        type: 'object',
        properties: {
          minutes: { type: 'number', description: 'minutes from now until the reminder fires' },
          label: { type: 'string', description: 'what to remind the user about' },
        },
        required: ['minutes', 'label'],
      },
      handler: async ({ minutes, label }) => {
        const ms = Math.max(1, Number(minutes) || 0) * 60000;
        const r = addReminder(String(label || 'Reminder'), ms);
        win?.webContents.send('ai-tool', { kind: 'reminder', label: `Reminder set · ${humanizeMs(ms)}` });
        return `Reminder set for ${humanizeMs(ms)} from now: "${r.label}".`;
      },
    }),
  };

  ai.abort = new AbortController();
  // Watchdog: a 3B model can occasionally wedge mid-generation and never
  // return, leaving the panel stuck on "Thinking…". Abort after 90s so the
  // user gets control back instead of an infinite spinner. (A real search +
  // answer is well under this.)
  let watchdogHit = false;
  const watchdog = setTimeout(() => {
    watchdogHit = true;
    try { ai.abort?.abort(); } catch {}
  }, 90000);
  try {
    await ai.session.prompt(prompt, {
      signal: ai.abort.signal,
      functions,
      // NOTE: do NOT add '<tool_call>' as a stop trigger — that's Qwen's real
      // function-call syntax, and stopping on it kills tool use. Leaked/role-
      // played markers are stripped on the renderer side instead.
      // bounded + penalized generation: small local models loop without this.
      // Roomier cap so answers aren't cut short, still safe from runaways.
      maxTokens: 1700,
      // lower temp = the model reliably commits to a tool call instead of
      // writing a chatty "let me search…" preamble and stalling
      temperature: 0.5,
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
    if (watchdogHit) {
      win?.webContents.send('ai-chunk', '\n\n_(That took too long, so I stopped. Try asking again.)_');
    }
  }
  clearTimeout(watchdog);
  ai.generating = false;
  win?.webContents.send('ai-done');
  sendAI({ state: 'ready' });
});

ipcMain.on('ai-stop', () => {
  ai.abort?.abort();
});

// Active reminders for the Settings → Reminders tab.
ipcMain.handle('get-reminders', () => getReminders());
ipcMain.on('delete-reminder', (_e, id) => removeReminder(id));

// Cancel a reminder with a confirmation prompt (used by the sidebar ✕).
ipcMain.handle('delete-reminder-confirm', async (_e, id) => {
  const r = getReminders().find((x) => x.id === id);
  if (!r) return;
  const { response } = await dialog.showMessageBox(win, {
    type: 'question',
    buttons: ['Keep it', 'Cancel reminder'],
    defaultId: 0,
    cancelId: 0,
    message: 'Are you sure you want to cancel this reminder?',
    detail: `"${r.label}"`,
  });
  if (response === 1) removeReminder(id);
});

// Notification overlay: it reports the size it needs, and routes button actions.
ipcMain.on('overlay-size', (_e, { w, h }) => positionOverlay(w, h));
ipcMain.on('overlay-action', (_e, action) => {
  if (action === 'open-downloads') openInternalTab(DOWNLOADS_URL);
  else if (action === 'install-update') {
    if (updateDownloaded) { installingUpdate = true; getAutoUpdater().quitAndInstall(); }
  }
});

ipcMain.on('ai-new-chat', () => {
  if (ai.ready && !ai.generating) {
    newChat();
    win?.webContents.send('ai-cleared');
  }
});

// ---------------------------------------------------------------------------
// Local chat history — conversations stored encrypted on this device
// ---------------------------------------------------------------------------

const chatsPath = () => path.join(app.getPath('userData'), 'chats.bin');
let chats = []; // [{ id, title, ts, messages:[{role,text|src}], llama }]

function loadChats() {
  try {
    chats = decryptFromFile(chatsPath());
  } catch {
    chats = [];
  }
}
function saveChats() {
  encryptToFile(chatsPath(), chats.slice(0, 200));
}

ipcMain.handle('chat-list', () =>
  chats
    .map((c) => ({ id: c.id, title: c.title, ts: c.ts }))
    .sort((a, b) => b.ts - a.ts)
);
ipcMain.handle('chat-load', async (_e, id) => {
  const c = chats.find((x) => x.id === id);
  if (!c) return null;
  // restore the model's context for this conversation when possible
  if (ai.ready && ai.session && Array.isArray(c.llama)) {
    try {
      ai.session.setChatHistory(c.llama);
    } catch {}
  }
  return { messages: c.messages || [] };
});
ipcMain.on('chat-save', (_e, { id, title, messages }) => {
  let c = chats.find((x) => x.id === id);
  if (!c) {
    c = { id };
    chats.push(c);
  }
  c.title = title || 'New chat';
  c.messages = messages || [];
  c.ts = Date.now();
  try {
    c.llama = ai.session ? ai.session.getChatHistory() : null;
  } catch {
    c.llama = null;
  }
  saveChats();
  win?.webContents.send('chats-changed');
});
ipcMain.on('chat-delete', (_e, id) => {
  chats = chats.filter((x) => x.id !== id);
  saveChats();
  win?.webContents.send('chats-changed');
});

// ---------------------------------------------------------------------------
// Auto update
// ---------------------------------------------------------------------------

// One shared electron-updater instance; the 'update-downloaded' wiring is
// attached exactly once so both the automatic and manual checks reuse it.
let autoUpdaterRef = null;
function getAutoUpdater() {
  if (autoUpdaterRef) return autoUpdaterRef;
  const { autoUpdater } = require('electron-updater');
  autoUpdater.autoDownload = true;
  // Detected a newer version (checked on every launch + every 4h) — tell the
  // user immediately, then again (persistently) once it's downloaded & ready.
  autoUpdater.on('update-available', (info) => {
    showToast({ kind: 'update', text: `New version ${info?.version || ''} found — downloading…`.trim() });
  });
  autoUpdater.on('update-downloaded', () => {
    updateDownloaded = true;
    showToast({ kind: 'update', text: 'Update ready', persist: true });
  });
  autoUpdaterRef = autoUpdater;
  return autoUpdater;
}

function setupAutoUpdate() {
  if (!app.isPackaged) return; // dev mode: electron-updater is inert
  try {
    const au = getAutoUpdater();
    au.checkForUpdatesAndNotify().catch(() => {}); // silent check on launch
    // re-check every 4 hours while running
    setInterval(() => au.checkForUpdates().catch(() => {}), 4 * 60 * 60 * 1000);
  } catch (err) {
    console.error('Auto-update unavailable:', err.message);
  }
}

// Menu "Check for Updates…" — same engine, but with explicit user feedback.
let manualCheckBusy = false;
async function checkForUpdatesManual() {
  const v = app.getVersion();
  if (!app.isPackaged) {
    dialog.showMessageBox(win, {
      type: 'info',
      message: 'Updates are only available in the installed app.',
      detail: `You're running a development build (v${v}).`,
      buttons: ['OK'],
    });
    return;
  }
  if (updateDownloaded) {
    const { response } = await dialog.showMessageBox(win, {
      type: 'info',
      message: 'An update is ready to install.',
      detail: 'Breeze will restart to finish updating.',
      buttons: ['Restart Now', 'Later'],
      defaultId: 0,
      cancelId: 1,
    });
    if (response === 0) { updateDownloaded = false; installingUpdate = true; getAutoUpdater().quitAndInstall(); }
    return;
  }
  if (manualCheckBusy) return;
  manualCheckBusy = true;
  let au;
  try {
    au = getAutoUpdater();
  } catch (err) {
    manualCheckBusy = false;
    dialog.showMessageBox(win, { type: 'error', message: 'Update check unavailable', detail: err.message, buttons: ['OK'] });
    return;
  }
  const done = () => {
    manualCheckBusy = false;
    au.removeListener('update-not-available', onNone);
    au.removeListener('update-available', onYes);
    au.removeListener('error', onErr);
  };
  const onNone = () => {
    done();
    dialog.showMessageBox(win, { type: 'info', message: "You're up to date", detail: `Breeze v${v} is the latest version.`, buttons: ['OK'] });
  };
  const onYes = (info) => {
    done();
    dialog.showMessageBox(win, {
      type: 'info',
      message: `Update available — v${info?.version || ''}`.trim(),
      detail: "Downloading now. You'll be prompted to restart when it's ready.",
      buttons: ['OK'],
    });
  };
  const onErr = (err) => {
    done();
    dialog.showMessageBox(win, { type: 'error', message: 'Could not check for updates', detail: String((err && err.message) || err), buttons: ['OK'] });
  };
  au.once('update-not-available', onNone);
  au.once('update-available', onYes);
  au.once('error', onErr);
  try { await au.checkForUpdates(); } catch { /* 'error' event handles UI */ }
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

let lastAppliedTheme = null;

function applyTheme(theme) {
  // Only assign when it actually changes: setting themeSource re-fires
  // nativeTheme 'updated', and our 'updated' handler calls applyTheme —
  // an unconditional assignment here spins that loop forever (~30% CPU idle).
  const src = theme === 'system' ? 'system' : theme;
  if (nativeTheme.themeSource !== src) nativeTheme.themeSource = src;
  const eff = effectiveTheme();
  if (eff === lastAppliedTheme) return;
  lastAppliedTheme = eff;
  if (win) {
    win.setBackgroundColor(eff === 'dark' ? '#16161a' : '#f2f0ed');
    win.webContents.send('theme', eff);
  }
  try { overlayView?.webContents.send('overlay-theme', eff); } catch {}
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
    // y chosen so the lights' vertical center lines up with the sidebar's
    // top icon row (sidebar padding-top 12 + 40px strip center = ~32).
    trafficLightPosition: { x: 18, y: 25 },
    backgroundColor: theme === 'dark' ? '#16161a' : '#f2f0ed',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
    },
  });

  win.loadFile(path.join(__dirname, 'ui', 'index.html'));
  createOverlay();
  if (process.platform === 'darwin' && !sidebarVisible) {
    try {
      win.setWindowButtonVisibility(false);
    } catch {}
  }
  win.on('resize', applyBounds);
  win.on('enter-full-screen', () => {
    win?.webContents.send('app-fullscreen', true);
    startCornerPoll();
  });
  win.on('leave-full-screen', () => {
    win?.webContents.send('app-fullscreen', false);
    stopCornerPoll();
  });
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
    if (appSettings.onboarded) restoreSessionOrNewTab();
    // One-shot "what's new" popup after an update. Only for already-onboarded
    // users (never on a brand-new install) and only when the version changed.
    // BREEZE_WHATSNEW_FROM forces it for testing without touching real settings.
    const curV = app.getVersion();
    const force = process.env.BREEZE_WHATSNEW_FROM;
    const seenV = force || appSettings.lastSeenVersion || '';
    if (force || (appSettings.onboarded && seenV !== curV)) {
      // Detach page views HERE (synchronously, after restore) so the popup is
      // never covered — restored tabs attach a real page view, and relying on a
      // renderer round-trip to detach raced with that (resume users missed it).
      for (const t of tabs.values()) {
        if (t.view) { try { win.contentView.removeChildView(t.view); } catch {} }
      }
      win.webContents.send('whats-new', { version: curV, from: seenV || null });
    }
    if (!force && (appSettings.lastSeenVersion || '') !== curV) {
      applySetting('lastSeenVersion', curV);
    }
  });
}

function buildMenu() {
  const isMac = process.platform === 'darwin';
  const template = [
    ...(isMac
      ? [
          {
            label: app.name,
            submenu: [
              { role: 'about' },
              { label: 'Check for Updates…', click: () => checkForUpdatesManual() },
              { type: 'separator' },
              { role: 'services' },
              { type: 'separator' },
              { role: 'hide' },
              { role: 'hideOthers' },
              { role: 'unhide' },
              { type: 'separator' },
              { role: 'quit' },
            ],
          },
        ]
      : []),
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
          click: () => toggleAssistant(),
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
    {
      role: 'help',
      submenu: [
        // On macOS "Check for Updates…" also lives in the Breeze app menu;
        // here it gives Windows/Linux a home and a second access point.
        { label: 'Check for Updates…', click: () => checkForUpdatesManual() },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// ---------------------------------------------------------------------------
// IPC
// ---------------------------------------------------------------------------

ipcMain.on('new-tab', () => createTab());
ipcMain.on('close-tab', (_e, id) => closeTab(id));
ipcMain.on('activate-tab', (_e, id) => activateTab(id));
// Navigating across the internal(file://)<->web boundary must REBUILD the
// view: the preload is fixed at view creation, and a newtab's internal-preload
// lacks what web pages need (PiP routing, link pre-warm, creds, AI selection).
function loadInTab(t, url) {
  if (!t) return;
  if (t.id === activeTabId) autoDockAI(); // navigating the page docks a FS chat
  t.loadTimes = []; t.stormStopped = false; // explicit nav re-arms the guard
  if (!t.view) {
    buildView(t, url);
    win.contentView.addChildView(t.view);
    applyBounds();
    return;
  }
  const wantInternal = url.startsWith('file://');
  if (t.preloadInternal === wantInternal) {
    t.view.webContents.loadURL(url);
    return;
  }
  win.contentView.removeChildView(t.view);
  t.view.webContents.close();
  t.view = null;
  buildView(t, url);
  win.contentView.addChildView(t.view);
  applyBounds();
  t.view.webContents.focus();
}

function loadInActiveTab(url) {
  loadInTab(tabs.get(activeTabId), url);
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// Renders the "something went wrong" page after a reload storm is stopped.
// Static self-contained HTML (no preload needed) loaded as a data URL; the
// Try-again link points at the original URL so a click re-arms the guard via
// will-navigate and gives the page a fresh budget.
function showReloadStormPage(t) {
  const wc = t.view?.webContents;
  if (!wc) return;
  const target = t.lastNavUrl || '';
  let host = target;
  try { host = new URL(target).host || target; } catch {}
  const err = t.lastError;
  const detail = err
    ? `Network error: ${escapeHtml(err.desc || 'failed to load')} (${err.code})`
    : 'The page kept reloading itself and was stopped to protect your browser.';
  const retry = /^https?:/i.test(target)
    ? `<a class="btn" href="${escapeHtml(target)}">Try again</a>`
    : '';
  const html = `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  :root { color-scheme: light dark; }
  html,body { height:100%; margin:0; }
  body { display:grid; place-items:center; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
    background:#f2f0ed; color:#1c1c1e; }
  @media (prefers-color-scheme: dark) { body { background:#16161a; color:#ececf1; } }
  .card { max-width:440px; text-align:center; padding:0 28px; }
  .icon { font-size:46px; margin-bottom:14px; }
  h1 { font-size:22px; font-weight:700; letter-spacing:-0.4px; margin:0 0 10px; }
  p { font-size:14.5px; line-height:1.6; opacity:0.8; margin:0 0 8px; }
  .host { font-weight:600; opacity:1; word-break:break-all; }
  .detail { font-size:13px; opacity:0.65; margin-top:6px; }
  .btn { display:inline-block; margin-top:22px; padding:11px 22px; border-radius:12px;
    background:#5b7cfa; color:#fff; text-decoration:none; font-size:14.5px; font-weight:600; }
  .btn:active { transform:scale(0.97); }
</style></head>
<body><div class="card">
  <div class="icon">🥴</div>
  <h1>Something went wrong</h1>
  <p>Breeze stopped <span class="host">${escapeHtml(host || 'this page')}</span> after it reloaded too many times in a row.</p>
  <p class="detail">${detail}</p>
  ${retry}
</div></body></html>`;
  wc.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html));
}

ipcMain.on('navigate', (_e, input) => {
  const url = toNavigableURL(input);
  if (url) loadInActiveTab(url);
});
// Per-pane navigation from the split-view URL bars (operates on a specific tab,
// not just the active one).
ipcMain.on('tab-navigate', (_e, { id, input }) => {
  const t = tabs.get(id);
  if (!t) return;
  const url = toNavigableURL(input);
  if (url) loadInTab(t, url);
});
ipcMain.on('tab-nav', (_e, { id, action }) => {
  const t = tabs.get(id);
  if (!t || !t.view) return;
  const wc = t.view.webContents;
  if (action === 'back') wc.navigationHistory.goBack();
  else if (action === 'forward') wc.navigationHistory.goForward();
  else if (action === 'reload') wc.reload();
});
ipcMain.on('open-url', (_e, url) => loadInActiveTab(url));
ipcMain.on('copy-text', (_e, text) => {
  if (text) try { clipboard.writeText(String(text)); } catch {}
});
// Native share. macOS gets the real share sheet (ShareMenu); elsewhere we fall
// back to copying the link (no cross-platform share API in Electron).
ipcMain.on('share-url', (_e, url) => {
  if (!url) return;
  if (process.platform === 'darwin') {
    try {
      const { ShareMenu } = require('electron');
      new ShareMenu({ urls: [url] }).popup({ window: win });
      return;
    } catch {}
  }
  try { clipboard.writeText(String(url)); } catch {}
});
ipcMain.on('open-url-new-tab', (_e, url) => createTab(url, true));
ipcMain.on('go-back', () => activeWC()?.navigationHistory.goBack());
ipcMain.on('go-forward', () => activeWC()?.navigationHistory.goForward());
ipcMain.on('reload', () => activeWC()?.reload());
ipcMain.on('toggle-sidebar', () => setSidebar(!sidebarVisible));
ipcMain.on('toggle-assistant', () => toggleAssistant());
ipcMain.on('ai-fullscreen-set', (_e, on) => setAIFullscreen(on));
// What's-new popup dismissed → reattach the active (and split) page view.
ipcMain.on('whats-new-done', () => {
  const a = tabs.get(activeTabId);
  const s = splitTabId ? tabs.get(splitTabId) : null;
  for (const v of [a, s]) {
    if (v?.view) { try { win.contentView.addChildView(v.view); } catch {} }
  }
  applyBounds();
  raiseOverlay();
});
// New-tab Dia input → send a chat: open the assistant fullscreen and submit.
ipcMain.on('ai-ask-from-newtab', (_e, text) => {
  const t = String(text || '').trim();
  if (!t) return;
  setAssistant(true);
  setAIFullscreen(true);
  win?.webContents.send('ai-submit', t);
});
ipcMain.on('toggle-bookmark', () => toggleBookmark());
// URL-bar bell: flip this site's notification permission (per-site override)
ipcMain.on('toggle-site-notif', (_e, origin) => {
  if (!origin) return;
  const perms = appSettings.permissions || {};
  const next = !notifAllowed(origin);
  perms[origin] = { ...perms[origin], notifications: next };
  applySetting('permissions', perms);
  pushState();
});
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
  installingUpdate = true;
  const { autoUpdater } = require('electron-updater');
  autoUpdater.quitAndInstall();
});
// Synchronous theme lookup so internal pages can paint the right theme on the
// very first frame (no light→dark flash). Used by internal-preload.
ipcMain.on('get-theme-sync', (e) => { e.returnValue = effectiveTheme(); });
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
ipcMain.on('enter-split', (_e, id) => enterSplit(id));
ipcMain.on('exit-split', () => exitSplit());
ipcMain.on('set-split-ratio', (_e, r) => {
  splitRatio = Math.min(0.85, Math.max(0.15, r));
  applyBounds();
});
ipcMain.on('reorder-tabs', (_e, ids) => {
  // ids = the new order of the ungrouped/unpinned list tabs; slot them back
  // into the positions they occupied in the master tab order.
  const slots = [];
  tabOrder.forEach((id, i) => {
    if (ids.includes(id)) slots.push(i);
  });
  ids.forEach((id, k) => {
    if (slots[k] !== undefined) tabOrder[slots[k]] = id;
  });
  pushState();
});
ipcMain.on('toggle-group-collapse', (_e, gid) => {
  const g = groups.find((x) => x.id === gid);
  if (g) {
    // default (undefined) is collapsed, so flip the EFFECTIVE state:
    // expanded (collapsed===false) → collapse (true); otherwise → expand (false)
    g.collapsed = g.collapsed === false;
    saveGroups();
    pushState();
  }
});
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

// Danger zone: clear browsing data with a custom selection (cache / cookies /
// history), any combination — like every other browser.
ipcMain.handle('clear-browsing-data', async (_e, opts = {}) => {
  const ses = session.defaultSession;
  try {
    if (opts.history) {
      history = [];
      try { encryptToFile(historyPath(), history); } catch {}
    }
    if (opts.cache) {
      await ses.clearCache();
      try { await ses.clearStorageData({ storages: ['cachestorage', 'shadercache'] }); } catch {}
    }
    if (opts.cookies) {
      await ses.clearStorageData({ storages: ['cookies'] });
    }
  } catch (e) {
    return { ok: false, error: e.message };
  }
  return { ok: true };
});

// Danger zone: full factory reset. Confirmed with a native dialog, then wipes
// everything and restarts so the app comes back truly fresh.
ipcMain.handle('reset-browser', async () => {
  const { response } = await dialog.showMessageBox(win, {
    type: 'warning',
    buttons: ['Cancel', 'Reset everything'],
    defaultId: 0,
    cancelId: 0,
    message: 'Reset Breeze to factory settings?',
    detail:
      'This permanently deletes your history, cookies, cache, saved passwords, ' +
      'downloads list, bookmarks, pins, saved chats, and all settings. This ' +
      'cannot be undone. Breeze will restart.',
  });
  if (response !== 1) return { ok: false, cancelled: true };
  try {
    const ses = session.defaultSession;
    await ses.clearCache();
    await ses.clearStorageData();
  } catch {}
  history = [];
  downloadList = [];
  vault = [];
  for (const p of [historyPath(), legacyHistoryPath(), vaultPath(), downloadsPath(), chatsPath(), settingsPath()]) {
    try { fs.rmSync(p, { force: true }); } catch {}
  }
  // mark a clean exit so the next launch doesn't think it crashed
  try { markCleanExit(); } catch {}
  app.relaunch();
  app.exit(0);
  return { ok: true };
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
ipcMain.on('open-settings', (_e, section) => openSettingsTab(section));

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
      restoreSessionOrNewTab();
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
    // only the disposable caches — these always rebuild, no data loss. The main
    // network "Cache" is included because a half-written HTTP cache (e.g. after a
    // hard quit) serves truncated JS/CSS/sprites/fonts → sites render with
    // missing logos/icons (classic YouTube symptom). It just re-downloads.
    const dir = app.getPath('userData');
    for (const sub of [
      'Cache',
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
  loadChats();
  loadDownloads();
  initReminders();
  setupDownloads(session.defaultSession);
  setupPermissions(session.defaultSession);
  await setupAdblock();
  buildMenu();
  createWindow();
  setupAutoUpdate();
  warmConnections();
  // Start pulling the AI model in the background so it's ready (or already
  // downloaded) by the time the user opens the assistant. Delayed so it doesn't
  // contend with first-paint / page loads.
  setTimeout(() => { try { prefetchModel(); } catch {} }, 4000);

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
  // Tab session restore. Decide whether to remember this session's tabs.
  // Done first, while the window + views are still alive (the disposal below
  // tears the AI down but tabs are untouched). app.exit() bypasses before-quit,
  // so the reset-relaunch path never reaches here.
  try {
    const urls = captureSessionTabs();
    const mode = appSettings.restoreTabs || 'ask';
    if (installingUpdate) {
      // Auto-quit for an update: can't prompt. Preserve tabs unless the user
      // has explicitly opted out, so they come back to where they were.
      saveSettings({ savedTabs: mode === 'never' ? [] : urls });
    } else if (mode === 'never' || urls.length === 0) {
      if ((appSettings.savedTabs || []).length) saveSettings({ savedTabs: [] });
    } else if (mode === 'always') {
      saveSettings({ savedTabs: urls });
    } else {
      // 'ask' — prompt once, with a "remember my choice" checkbox that flips
      // the mode to always/never so we never nag again unless they want it.
      const { response, checkboxChecked } = dialog.showMessageBoxSync(win, {
        type: 'question',
        buttons: ['Reopen Tabs', "Don't Reopen"],
        defaultId: 0,
        cancelId: 1,
        title: 'Quit Breeze',
        message: `Reopen your ${urls.length} ${urls.length === 1 ? 'tab' : 'tabs'} next time?`,
        detail: 'Breeze can restore the pages you have open when you launch again.',
        checkboxLabel: 'Remember my choice',
        checkboxChecked: false,
        noLink: true,
      });
      const reopen = response === 0;
      const patch = { savedTabs: reopen ? urls : [] };
      if (checkboxChecked) patch.restoreTabs = reopen ? 'always' : 'never';
      saveSettings(patch);
    }
  } catch {}

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
  // node-llama-cpp's native (Metal) worker threads keep the process alive
  // after the windows are gone — ⌘Q looked dead until force quit. Release
  // everything; each dispose is independent so one failure can't skip the rest.
  try { clearTimeout(ai.idleTimer); } catch {}
  try { ai.abort?.abort(); } catch {}
  try { ai.session?.dispose(); } catch {}
  try { ai.sequence?.dispose(); } catch {}
  try { ai.context?.dispose(); } catch {}
  try { ai.model?.dispose(); } catch {}
  try { ai.llama?.dispose(); } catch {}
});

// belt-and-suspenders: also flush on hard process signals
app.on('will-quit', () => {
  markCleanExit();
  // node-llama-cpp's native (Metal/GGML) worker can throw during Node's
  // FreeEnvironment teardown → SIGABRT crash report on an otherwise clean quit.
  // We've already disposed + flushed, so hard-exit before that teardown runs.
  // (Skip during an update install — Squirrel needs the graceful quit to swap.)
  if (!installingUpdate) {
    setTimeout(() => { try { app.exit(0); } catch {} }, 120);
  }
});
process.on('exit', markCleanExit);

// Backstop: if any native thread still pins the process after quit, end it.
// The timer is unref'd, so a clean exit is never delayed by it.
app.on('quit', () => {
  setTimeout(() => process.exit(0), 1500).unref();
});
