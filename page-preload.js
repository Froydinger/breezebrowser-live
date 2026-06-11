// Injected into every web tab. Watches link hovers and asks the main process
// to pre-warm the connection (DNS + TCP + TLS) so clicks feel instant.
// Exposes nothing to the page.
const { ipcRenderer } = require('electron');

let lastHref = '';
let lastTime = 0;

// When the PiP window closes, keep the video playing in its tab instead of
// letting Chromium pause it. (Closing the tab kills the document, which
// closes PiP automatically — that direction needs no code.)
window.addEventListener(
  'leavepictureinpicture',
  (e) => {
    const v = e.target;
    if (v && v.tagName === 'VIDEO' && v.paused && !v.ended) {
      setTimeout(() => v.play().catch(() => {}), 0);
    }
  },
  { capture: true }
);

// Offer to save credentials when a login form is submitted.
window.addEventListener(
  'submit',
  (e) => {
    try {
      const form = e.target;
      if (!form || !form.querySelector) return;
      const pass = form.querySelector('input[type="password"]');
      if (!pass || !pass.value) return;
      const userEl = form.querySelector(
        'input[type="email"], input[autocomplete*="username" i], input[type="text"]'
      );
      ipcRenderer.send('cred-captured', {
        origin: location.origin,
        username: (userEl && userEl.value) || '',
        password: pass.value,
      });
    } catch {}
  },
  { capture: true }
);

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
