// Preload for the notification overlay — a tiny transparent WebContentsView
// pinned ABOVE the page views so essential toasts (downloads, updates) are
// visible regardless of sidebar state. Sized to exactly its content so it never
// blocks clicks to the page when idle.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('overlay', {
  onToast: (cb) => ipcRenderer.on('toast', (_e, d) => cb(d)),
  onTheme: (cb) => ipcRenderer.on('overlay-theme', (_e, t) => cb(t)),
  size: (w, h) => ipcRenderer.send('overlay-size', { w, h }),
  action: (a) => ipcRenderer.send('overlay-action', a),
});
