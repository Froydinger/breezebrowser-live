// Injected into every web tab. Watches link hovers and asks the main process
// to pre-warm the connection (DNS + TCP + TLS) so clicks feel instant.
// Exposes nothing to the page.
const { ipcRenderer } = require('electron');

let lastHref = '';
let lastTime = 0;

window.addEventListener(
  'mouseover',
  (e) => {
    const a = e.target && e.target.closest && e.target.closest('a[href]');
    if (!a) return;
    const href = a.href;
    if (!href || !/^https?:/.test(href)) return;
    if (href === lastHref && Date.now() - lastTime < 5000) return;
    lastHref = href;
    lastTime = Date.now();
    ipcRenderer.send('link-hover', href);
  },
  { passive: true, capture: true }
);
