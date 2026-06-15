// Preload for Breeze's internal pages (new tab, settings).
const { contextBridge, ipcRenderer } = require('electron');

// Resolved once, synchronously, at preload time — so internal pages can apply
// the right theme class BEFORE first paint and avoid a light→dark flash.
let initialTheme = 'light';
try { initialTheme = ipcRenderer.sendSync('get-theme-sync') || 'light'; } catch {}

contextBridge.exposeInMainWorld('breezeInternal', {
  theme: initialTheme,
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

  setSitePermission: (origin, permission, value) =>
    ipcRenderer.send('set-site-permission', { origin, permission, value }),

  getReminders: () => ipcRenderer.invoke('get-reminders'),
  deleteReminder: (id) => ipcRenderer.send('delete-reminder', id),
  onReminders: (cb) => ipcRenderer.on('reminders-changed', (_e, r) => cb(r)),

  clearBrowsingData: (opts) => ipcRenderer.invoke('clear-browsing-data', opts),
  resetBrowser: () => ipcRenderer.invoke('reset-browser'),

  isDefaultBrowser: () => ipcRenderer.invoke('is-default-browser'),
  makeDefaultBrowser: () => ipcRenderer.send('make-default-browser'),
  switchToTab: (id) => ipcRenderer.send('switch-to-tab', id),
  askAI: (text) => ipcRenderer.send('ai-ask-from-newtab', text),
  getModelInfo: () => ipcRenderer.invoke('get-model-info'),
  setAIModel: (tier) => ipcRenderer.send('set-ai-model', tier),
  onFocusInput: (cb) => ipcRenderer.on('focus-newtab-input', () => cb()),

  importSources: () => ipcRenderer.invoke('import-sources'),
  importFromBrowser: (path, kind, target) =>
    ipcRenderer.invoke('import-from-browser', { path, kind, target }),
  importHTML: (html, target) => ipcRenderer.invoke('import-html', { html, target }),

  vaultList: () => ipcRenderer.invoke('vault-list'),
  vaultAdd: (site, username, password) =>
    ipcRenderer.send('vault-add', { site, username, password }),
  vaultDelete: (id) => ipcRenderer.send('vault-delete', id),
  vaultImportCSV: (csv) => ipcRenderer.send('vault-import-csv', csv),
  onVault: (cb) => ipcRenderer.on('vault', (_e, v) => cb(v)),
  onVaultImported: (cb) => ipcRenderer.on('vault-imported', (_e, n) => cb(n)),
});
