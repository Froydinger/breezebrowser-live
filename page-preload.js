// Injected into every web tab. Watches link hovers and asks the main process
// to pre-warm the connection (DNS + TCP + TLS) so clicks feel instant.
// Exposes nothing to the page.
const { ipcRenderer } = require('electron');

let lastHref = '';
let lastTime = 0;

// Track whether this page owns the native PiP window, so main can route the
// PiP "back to tab" button to the right tab.
window.addEventListener(
  'enterpictureinpicture',
  () => ipcRenderer.send('pip-state', true),
  { capture: true }
);

// When the PiP window closes, keep the video playing in its tab instead of
// letting Chromium pause it. (Closing the tab kills the document, which
// closes PiP automatically — that direction needs no code.)
window.addEventListener(
  'leavepictureinpicture',
  (e) => {
    ipcRenderer.send('pip-state', false);
    // Chromium pauses the video shortly AFTER this event when the tab is
    // hidden — only re-assert play if it was playing when PiP closed (a
    // video the user paused stays paused).
    const v = e.target;
    if (v && v.tagName === 'VIDEO' && !v.ended && !v.paused) {
      const resume = () => {
        if (v.paused && !v.ended) v.play().catch(() => {});
      };
      setTimeout(resume, 0);
      setTimeout(resume, 150);
      setTimeout(resume, 400);
    }
  },
  { capture: true }
);

// Proactive autofill offer: when the user focuses a login field on a site we
// have a saved credential for, show a small "Fill saved login" chip anchored
// to the field. Click fills username + password. Built in a shadow root so
// page CSS can't touch it; passwords stay in this isolated world (never the
// page's JS). One offer per page; dismiss on outside click or Esc.
(() => {
  let creds = null; // cached for this page after first lookup
  let chip = null;
  let dismissed = false;

  const findPassword = () =>
    document.querySelector('input[type="password"]:not([disabled])');
  const findUsername = (pass) => {
    const form = pass && pass.closest ? pass.closest('form') : document;
    return (form || document).querySelector(
      'input[type="email"], input[autocomplete*="username" i], input[type="text"]:not([disabled])'
    );
  };

  function removeChip() {
    if (chip) { chip.remove(); chip = null; }
  }

  function fill(cred, pass) {
    const set = (el, v) => {
      if (!el) return;
      const proto = Object.getPrototypeOf(el);
      const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
      setter ? setter.call(el, v) : (el.value = v);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    set(findUsername(pass), cred.username);
    set(pass, cred.password);
    removeChipFull();
  }

  let chipField = null; // the input the current chip is anchored to

  function reposition() {
    if (!chip || !chipField) return;
    const r = chipField.getBoundingClientRect();
    chip.style.left = `${window.scrollX + r.left}px`;
    chip.style.top = `${window.scrollY + r.bottom + 4}px`;
  }

  const esc = (s) => String(s || '').replace(/[<>&"]/g, (c) =>
    ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' }[c]));

  function showChip(field, pass) {
    if (chip || dismissed) return;
    const multi = creds.length > 1;
    const host = document.createElement('div');
    host.style.cssText = 'position:absolute;z-index:2147483647;';
    const root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `
      <style>
        :host{all:initial}
        .b{display:inline-flex;align-items:center;gap:7px;
           font:500 12px -apple-system,system-ui,sans-serif;color:#fff;
           background:#1e1e24;border:1px solid rgba(255,255,255,.14);
           border-radius:9px;padding:7px 10px;cursor:pointer;
           box-shadow:0 6px 22px rgba(0,0,0,.35)}
        .b:hover{background:#2c2c34}
        .k{font-size:13px}
        .u{opacity:.7}
        .car{opacity:.6;margin-left:1px;font-size:10px}
        .menu{margin-top:5px;background:#1e1e24;border:1px solid rgba(255,255,255,.14);
           border-radius:9px;box-shadow:0 6px 22px rgba(0,0,0,.35);overflow:hidden;
           min-width:170px}
        .item{display:flex;align-items:center;gap:8px;padding:8px 11px;cursor:pointer;
           font:500 12px -apple-system,system-ui,sans-serif;color:#fff}
        .item:hover{background:#2c2c34}
        .item .k{font-size:13px}
        .hidden{display:none}
      </style>
      <div class="b" role="button"><span class="k">🔑</span>
        <span>${multi ? 'Saved logins' : 'Fill saved login'}</span>
        ${!multi && creds[0].username ? `<span class="u">· ${esc(creds[0].username)}</span>` : ''}
        ${multi ? '<span class="car">▾</span>' : ''}
      </div>
      <div class="menu hidden">
        ${creds.map((c, idx) =>
          `<div class="item" data-idx="${idx}"><span class="k">👤</span><span>${esc(c.username) || '(no username)'}</span></div>`
        ).join('')}
      </div>`;

    const fillIdx = (idx) => fill(creds[idx], pass);

    if (multi) {
      const menu = root.querySelector('.menu');
      root.querySelector('.b').addEventListener('pointerdown', (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        menu.classList.toggle('hidden');
      });
      root.querySelectorAll('.item').forEach((el) =>
        el.addEventListener('pointerdown', (ev) => {
          ev.preventDefault();
          ev.stopPropagation();
          fillIdx(Number(el.dataset.idx));
        })
      );
    } else {
      // pointerdown (not click) so we fill before the field's own blur/click
      // can race the dismiss; preventDefault keeps focus where it is.
      root.querySelector('.b').addEventListener('pointerdown', (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        fillIdx(0);
      });
    }
    document.body.appendChild(host);
    chip = host;
    chipField = field;
    reposition();

    // Dismiss on a click that's truly outside — but NOT the click that just
    // spawned the chip (the field click), so defer attaching by a tick. The
    // chip lives in a closed shadow root, so clicks on it retarget to `host`.
    setTimeout(() => {
      if (!chip) return;
      const outside = (e) => {
        if (!chip) { document.removeEventListener('mousedown', outside, true); return; }
        if (e.target === chip || e.target === chipField) return;
        removeChip();
        document.removeEventListener('mousedown', outside, true);
      };
      document.addEventListener('mousedown', outside, true);
    }, 0);
  }

  function removeChipFull() { removeChip(); chipField = null; }

  async function onFocus(e) {
    if (dismissed || chip) return;
    const t = e.target;
    if (!t || t.tagName !== 'INPUT') return;
    const pass = findPassword();
    if (!pass) return;
    // only offer on the password field or its form's username field
    const userEl = findUsername(pass);
    if (t !== pass && t !== userEl) return;
    if (creds === null) {
      try { creds = await ipcRenderer.invoke('cred-check'); } catch { creds = []; }
    }
    if (creds && creds.length) showChip(t, pass);
  }

  document.addEventListener('focusin', onFocus, { capture: true });
  window.addEventListener('scroll', reposition, { passive: true, capture: true });
  window.addEventListener('resize', reposition, { passive: true });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && chip) { dismissed = true; removeChipFull(); }
  }, { capture: true });
})();

// Offer to save credentials on login. A plain `submit` event covers classic
// forms, but most big sites (X, Dropbox, Google…) log in via JS — no form
// submit ever fires. So we also remember the last password the user typed and
// flush it on the signals that accompany a JS login: clicking a submit/login
// control, pressing Enter in the password field, the page hiding, or a
// client-side navigation (URL change). Captures are deduped in main.
let lastCred = null; // { username, password } most recently entered

function snapshotCreds(passEl) {
  const pass =
    passEl && passEl.value
      ? passEl
      : [...document.querySelectorAll('input[type="password"]')].find((p) => p.value);
  if (!pass || !pass.value) return null;
  const scope = (pass.closest && pass.closest('form')) || document;
  const userEl = scope.querySelector(
    'input[type="email"], input[autocomplete*="username" i], input[autocomplete="email"], input[name*="user" i], input[name*="email" i], input[type="text"], input[type="tel"]'
  );
  return { username: (userEl && userEl.value) || '', password: pass.value };
}

function flushCred(snapshot) {
  const cred = snapshot || lastCred;
  if (!cred || !cred.password) return;
  ipcRenderer.send('cred-captured', {
    origin: location.origin,
    username: cred.username || '',
    password: cred.password,
  });
}

// keep the latest typed credentials fresh
document.addEventListener(
  'input',
  (e) => {
    const t = e.target;
    if (t && t.tagName === 'INPUT' && t.type === 'password' && t.value) {
      lastCred = snapshotCreds(t);
    }
  },
  { capture: true, passive: true }
);

// classic form submit
window.addEventListener('submit', () => flushCred(snapshotCreds()), { capture: true });

// JS logins: a click on a submit/login-looking control
document.addEventListener(
  'click',
  (e) => {
    const el = e.target && e.target.closest
      ? e.target.closest('button, input[type="submit"], [role="button"], a')
      : null;
    if (!el) return;
    const label = (
      el.innerText ||
      el.value ||
      el.getAttribute('aria-label') ||
      ''
    ).toLowerCase();
    const looksLikeLogin =
      el.type === 'submit' ||
      /log\s?in|sign\s?in|continue|next|submit|sign\s?up|register/.test(label);
    if (looksLikeLogin) {
      const snap = snapshotCreds();
      if (snap) { lastCred = snap; flushCred(snap); }
    }
  },
  { capture: true }
);

// Enter pressed inside a password field
document.addEventListener(
  'keydown',
  (e) => {
    if (e.key !== 'Enter') return;
    const t = e.target;
    if (t && t.tagName === 'INPUT' && t.type === 'password' && t.value) {
      const snap = snapshotCreds(t);
      lastCred = snap;
      flushCred(snap);
    }
  },
  { capture: true }
);

// SPA route change after a JS login (history API) — flush what we last saw
{
  const fire = () => setTimeout(() => flushCred(), 0);
  const wrap = (fn) => function () { const r = fn.apply(this, arguments); fire(); return r; };
  try {
    history.pushState = wrap(history.pushState);
    history.replaceState = wrap(history.replaceState);
    window.addEventListener('popstate', fire);
  } catch {}
}

// leaving the page (full navigation / tab close) — last chance to offer
window.addEventListener('pagehide', () => flushCred(), { capture: true });

// Report highlighted text so the AI panel can act on it. selectionchange is
// the only event that reliably fires across ALL pages (plain pages, editors,
// etc.) — but it fires a lot, so we ONLY listen while the AI panel is open
// (main toggles aiPanelOpen). Zero cost when the panel is closed.
let selTimer = null;
let lastSel = '';
let aiPanelOpen = false;

// Selection can live in three places window.getSelection() alone misses:
//  1. inside <input>/<textarea> (their own selectionStart/End),
//  2. inside shadow DOM (the active component's shadowRoot.getSelection()),
//  3. inside same-origin iframes (each frame has its own selection).
// Walk all of them so the AI sees what the user actually highlighted on any
// site — React apps, web components, editors included.
function readAnySelection() {
  // 1. focused form field with a real text selection
  const ae = document.activeElement;
  if (ae && (ae.tagName === 'TEXTAREA' || ae.tagName === 'INPUT')) {
    try {
      if (typeof ae.selectionStart === 'number' && ae.selectionEnd > ae.selectionStart) {
        return ae.value.slice(ae.selectionStart, ae.selectionEnd).trim();
      }
    } catch {}
  }
  // 2. shadow DOM: descend through open shadow roots that own a selection
  let root = document;
  for (let i = 0; i < 6; i++) {
    let sel = '';
    try { sel = String(root.getSelection ? root.getSelection() : '').trim(); } catch {}
    if (sel) return sel;
    const host = root.activeElement;
    if (host && host.shadowRoot && host.shadowRoot.getSelection) root = host.shadowRoot;
    else break;
  }
  // 3. top document
  try {
    const top = String(window.getSelection() || '').trim();
    if (top) return top;
  } catch {}
  // 4. same-origin iframes
  for (const frame of document.querySelectorAll('iframe')) {
    try {
      const s = String(frame.contentWindow.getSelection() || '').trim();
      if (s) return s;
    } catch {} // cross-origin — skip
  }
  return '';
}

function reportSelection() {
  if (!aiPanelOpen) return;
  clearTimeout(selTimer);
  selTimer = setTimeout(() => {
    const s = readAnySelection();
    if (s === lastSel) return;
    lastSel = s;
    ipcRenderer.send('page-selection', s.slice(0, 2000));
  }, 180);
}

ipcRenderer.on('ai-panel', (_e, open) => {
  aiPanelOpen = open;
  if (!open) {
    lastSel = '';
  } else {
    reportSelection(); // surface any current selection right away
  }
});

document.addEventListener('selectionchange', reportSelection, { passive: true });
document.addEventListener('mouseup', reportSelection, { passive: true, capture: true });
document.addEventListener('keyup', reportSelection, { passive: true, capture: true });
// fired by <input>/<textarea> when their internal selection changes
document.addEventListener('select', reportSelection, { passive: true, capture: true });

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
