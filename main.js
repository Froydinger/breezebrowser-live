const {
  app,
  BrowserWindow,
  WebContentsView,
  ipcMain,
  Menu,
  nativeTheme,
  session,
} = require('electron');
const path = require('path');
const fs = require('fs');

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const SIDEBAR_WIDTH = 280;
const ASSISTANT_WIDTH = 340;
const CONTENT_PAD = 10; // breathing room around the page, Arc-style

let win = null;
let blocker = null;
let updateDownloaded = false;

const tabs = new Map(); // id -> { id, view, favicon }
let tabOrder = [];
let activeTabId = null;
let nextTabId = 1;

let sidebarVisible = true;
let assistantVisible = false;
let layoutAnim = null;
let currentLeft = SIDEBAR_WIDTH;
let currentRight = 0;

let bookmarks = []; // [{ title, url }]

const NEWTAB_URL = `file://${path.join(__dirname, 'ui', 'newtab.html')}`;
const SETTINGS_URL = `file://${path.join(__dirname, 'ui', 'settings.html')}`;

const ENGINES = {
  google: 'https://www.google.com/search?q=',
  duckduckgo: 'https://duckduckgo.com/?q=',
  bing: 'https://www.bing.com/search?q=',
  brave: 'https://search.brave.com/search?q=',
};

const DEFAULT_SETTINGS = {
  theme: 'light',
  accent: '#5b7cfa',
  searchEngine: 'google',
  clock24: false,
  showGreeting: true,
  adblockEnabled: true,
  sidebarVisible: true,
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
  currentLeft = sidebarVisible ? SIDEBAR_WIDTH : 0;
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
  const toL = sidebarVisible ? SIDEBAR_WIDTH : 0;
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

function setSidebar(show) {
  sidebarVisible = show;
  saveSettings({ sidebarVisible: show });
  win?.webContents.send('sidebar', show);
  animateLayout();
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
  };
}

function pushState() {
  if (!win) return;
  win.webContents.send('state', {
    tabs: tabOrder.map((id) => tabState(tabs.get(id))),
    activeTabId,
    bookmarks,
  });
}

function createTab(url = NEWTAB_URL, activate = true) {
  const id = nextTabId++;
  const isInternal = url.startsWith('file://');
  const view = new WebContentsView({
    webPreferences: {
      sandbox: true,
      contextIsolation: true,
      ...(isInternal
        ? { preload: path.join(__dirname, 'internal-preload.js') }
        : {}),
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
  wc.setWindowOpenHandler(({ url }) => {
    createTab(url, true);
    return { action: 'deny' };
  });
  wc.on('enter-html-full-screen', () => {
    const [width, height] = win.getContentSize();
    view.setBounds({ x: 0, y: 0, width, height });
  });
  wc.on('leave-html-full-screen', applyBounds);

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
  return engine + encodeURIComponent(q);
}

function openSettingsTab() {
  for (const id of tabOrder) {
    if (tabs.get(id).view.webContents.getURL() === SETTINGS_URL) {
      activateTab(id);
      return;
    }
  }
  createTab(SETTINGS_URL, true);
}

// ---------------------------------------------------------------------------
// Bookmarks
// ---------------------------------------------------------------------------

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
});
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
ipcMain.on('set-setting', (_e, { key, value }) => {
  if (key in DEFAULT_SETTINGS) applySetting(key, value);
});
ipcMain.on('open-settings', () => openSettingsTab());

// ---------------------------------------------------------------------------
// App lifecycle
// ---------------------------------------------------------------------------

app.whenReady().then(async () => {
  appSettings = { ...DEFAULT_SETTINGS, ...loadSettings() };
  await setupAdblock();
  buildMenu();
  createWindow();
  setupAutoUpdate();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
