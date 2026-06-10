// Preload for Breeze's internal pages (new tab, settings).
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('breezeInternal', {
  getSettings: () => ipcRenderer.invoke('get-settings'),
  getSuggestions: (q) => ipcRenderer.invoke('get-suggestions', q),
  setSetting: (key, value) => ipcRenderer.send('set-setting', { key, value }),
  onSettings: (cb) => ipcRenderer.on('settings', (_e, s) => cb(s)),
  onTheme: (cb) => ipcRenderer.on('theme', (_e, t) => cb(t)),

  getBookmarks: () => ipcRenderer.invoke('get-bookmarks'),
  removeBookmark: (url) => ipcRenderer.send('remove-bookmark', url),
  onBookmarks: (cb) => ipcRenderer.on('bookmarks', (_e, b) => cb(b)),

  getHistory: () => ipcRenderer.invoke('get-history'),
  clearHistory: () => ipcRenderer.send('clear-history'),
  deleteHistoryItem: (url, ts) => ipcRenderer.send('delete-history-item', { url, ts }),

  getDownloads: () => ipcRenderer.invoke('get-downloads'),
  onDownloads: (cb) => ipcRenderer.on('downloads', (_e, d) => cb(d)),
  cancelDownload: (id) => ipcRenderer.send('download-cancel', id),
  openDownload: (id) => ipcRenderer.send('download-open', id),
  showDownload: (id) => ipcRenderer.send('download-show', id),
  clearDownloads: () => ipcRenderer.send('downloads-clear'),
});
