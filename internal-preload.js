// Preload for Breeze's internal pages (new tab, settings).
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('breezeInternal', {
  getSettings: () => ipcRenderer.invoke('get-settings'),
  setSetting: (key, value) => ipcRenderer.send('set-setting', { key, value }),
  onSettings: (cb) => ipcRenderer.on('settings', (_e, s) => cb(s)),
  onTheme: (cb) => ipcRenderer.on('theme', (_e, t) => cb(t)),
});
