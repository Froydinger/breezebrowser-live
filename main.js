const {
  app,
  BrowserWindow,
  WebContentsView,
  ipcMain,
  Menu,
  nativeTheme,
  session,
  shell,
} = require('electron');
const path = require('path');
const fs = require('fs');

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const SIDEBAR_WIDTH = 280;
const CONTENT_PAD = 10; // breathing room around the page, Arc-style

let win = null;
let blocker = null;
let updateDownloaded = false;

const tabs = new Map(); // id -> { id, view }
let tabOrder = [];
let activeTabId = null;
let nextTabId = 1;

let sidebarVisible = true;
let sidebarAnim = null; // running animation handle

const NEWTAB_URL = `file://${path.join(__dirname, 'ui', 'newtab.html')}`;

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
// Layout
// ---------------------------------------------------------------------------

function contentBounds(sidebarOffset) {
  // sidebarOffset: current visible width of the sidebar (animates 0..SIDEBAR_WIDTH)
  const [w, h] = win.getContentSize();
  return {
    x: Math.round(sidebarOffset) + CONTENT_PAD,
    y: CONTENT_PAD,
    width: Math.max(0, w - Math.round(sidebarOffset) - CONTENT_PAD * 2),
    height: Math.max(0, h - CONTENT_PAD * 2),
  };
}

function layout() {
  if (!win) return;
  const offset = sidebarVisible ? SIDEBAR_WIDTH : 0;
  const b = contentBounds(offset);
  for (const { view } of tabs.values()) view.setBounds(b);
}

function animateSidebar(show) {
  if (sidebarAnim) {
    clearInterval(sidebarAnim);
    sidebarAnim = null;
  }
  sidebarVisible = show;
  saveSettings({ sidebarVisible: show });
  win.webContents.send('sidebar', show);

  const DURATION = 240;
  const from = show ? 0 : SIDEBAR_WIDTH;
  const to = show ? SIDEBAR_WIDTH : 0;
  const start = Date.now();
  const easeOutCubic = (t) => 1 - Math.pow(1 - t, 3);

  sidebarAnim = setInterval(() => {
    const t = Math.min(1, (Date.now() - start) / DURATION);
    const offset = from + (to - from) * easeOutCubic(t);
    const b = contentBounds(offset);
    for (const { view } of tabs.values()) view.setBounds(b);
    if (t >= 1) {
      clearInterval(sidebarAnim);
      sidebarAnim = null;
    }
  }, 1000 / 60);
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

function tabState(t) {
  const wc = t.view.webContents;
  const url = wc.getURL();
  const isNewTab = url.startsWith('file://');
  return {
    id: t.id,
    title: isNewTab ? 'New Tab' : wc.getTitle() || 'Loading…',
    url: isNewTab ? '' : url,
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
  });
}

function createTab(url = NEWTAB_URL, activate = true) {
  const id = nextTabId++;
  const view = new WebContentsView({
    webPreferences: {
      sandbox: true,
      contextIsolation: true,
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
    view.setBounds({ x: 0, y: 0, ...sizeOf(win) });
  });
  wc.on('leave-html-full-screen', layout);

  wc.loadURL(url);
  if (activate) activateTab(id);
  else pushState();
  return id;
}

function sizeOf(w) {
  const [width, height] = w.getContentSize();
  return { width, height };
}

function activateTab(id) {
  const t = tabs.get(id);
  if (!t || !win) return;
  if (activeTabId && tabs.has(activeTabId)) {
    win.contentView.removeChildView(tabs.get(activeTabId).view);
  }
  activeTabId = id;
  win.contentView.addChildView(t.view);
  layout();
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
  if (tabOrder.length === 0) {
    if (tabs.size === 0 && winShouldClose) win.close();
    else createTab();
  }
  pushState();
}

let winShouldClose = false;

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
  return `https://www.google.com/search?q=${encodeURIComponent(q)}`;
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
    blocker.enableBlockingInSession(session.defaultSession);
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
}

function createWindow() {
  const settings = loadSettings();
  sidebarVisible = settings.sidebarVisible !== false;
  const theme = settings.theme || 'light';
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
  win.on('resize', layout);
  win.on('closed', () => {
    win = null;
  });
  win.on('close', () => {
    winShouldClose = true;
  });

  win.webContents.once('did-finish-load', () => {
    win.webContents.send('theme', theme);
    win.webContents.send('sidebar', sidebarVisible);
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
          click: () => animateSidebar(!sidebarVisible),
        },
        {
          label: 'Focus Address Bar',
          accelerator: 'CmdOrCtrl+L',
          click: () => {
            if (!sidebarVisible) animateSidebar(true);
            win?.webContents.send('focus-address');
          },
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
ipcMain.on('go-back', () => activeWC()?.navigationHistory.goBack());
ipcMain.on('go-forward', () => activeWC()?.navigationHistory.goForward());
ipcMain.on('reload', () => activeWC()?.reload());
ipcMain.on('toggle-sidebar', () => animateSidebar(!sidebarVisible));
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
}));

// ---------------------------------------------------------------------------
// App lifecycle
// ---------------------------------------------------------------------------

app.whenReady().then(async () => {
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
