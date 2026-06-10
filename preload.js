const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('breeze', {
  newTab: () => ipcRenderer.send('new-tab'),
  closeTab: (id) => ipcRenderer.send('close-tab', id),
  activateTab: (id) => ipcRenderer.send('activate-tab', id),
  navigate: (input) => ipcRenderer.send('navigate', input),
  goBack: () => ipcRenderer.send('go-back'),
  goForward: () => ipcRenderer.send('go-forward'),
  reload: () => ipcRenderer.send('reload'),
  toggleSidebar: () => ipcRenderer.send('toggle-sidebar'),
  setTheme: (theme) => ipcRenderer.send('set-theme', theme),
  installUpdate: () => ipcRenderer.send('install-update'),
  getInit: () => ipcRenderer.invoke('get-init'),

  onState: (cb) => ipcRenderer.on('state', (_e, s) => cb(s)),
  onTheme: (cb) => ipcRenderer.on('theme', (_e, t) => cb(t)),
  onSidebar: (cb) => ipcRenderer.on('sidebar', (_e, v) => cb(v)),
  onFocusAddress: (cb) => ipcRenderer.on('focus-address', () => cb()),
  onAdblockCount: (cb) => ipcRenderer.on('adblock-count', (_e, n) => cb(n)),
  onUpdateReady: (cb) => ipcRenderer.on('update-ready', () => cb()),
});
