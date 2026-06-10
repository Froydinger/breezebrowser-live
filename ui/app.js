const $ = (s) => document.querySelector(s);

const sidebar = $('#sidebar');
const tabsEl = $('#tabs');
const address = $('#address');
const btnBack = $('#btn-back');
const btnForward = $('#btn-forward');
const btnBookmark = $('#btn-bookmark');

let state = { tabs: [], activeTabId: null, bookmarks: [] };
let addressFocused = false;

// ---------------------------------------------------------------------------
// Icons
// ---------------------------------------------------------------------------

const globeIcon = `<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M2 8h12M8 2c-3.5 3.8-3.5 8.2 0 12 3.5-3.8 3.5-8.2 0-12z" fill="none" stroke="currentColor" stroke-width="1.2"/></svg>`;
const xIcon = `<svg viewBox="0 0 10 10"><path d="M1.5 1.5l7 7M8.5 1.5l-7 7" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>`;
const incogIcon = `<svg viewBox="0 0 16 16"><path d="M2 7.5h12M4 7.5l1.2-3.6a.8.8 0 0 1 .76-.55h4.08a.8.8 0 0 1 .76.55L12 7.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/><circle cx="4.8" cy="11" r="2.1" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="11.2" cy="11" r="2.1" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M6.9 11h2.2" stroke="currentColor" stroke-width="1.3"/></svg>`;

// Safe favicon rendering — build DOM nodes, never inline event handlers.
function setFavicon(el, src) {
  if (el.dataset.src === (src || '')) return; // unchanged, avoid flicker
  el.dataset.src = src || '';
  el.textContent = '';
  if (!src) {
    el.innerHTML = globeIcon;
    return;
  }
  const img = document.createElement('img');
  img.src = src;
  img.onerror = () => {
    el.dataset.src = '';
    el.innerHTML = globeIcon;
  };
  el.appendChild(img);
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

breeze.getInit().then(({ theme, sidebarVisible, settings }) => {
  applyTheme(theme);
  setSidebarVisible(sidebarVisible);
  if (settings) applySettings(settings);
});

function applySettings(s) {
  if (s.accent) document.documentElement.style.setProperty('--accent', s.accent);
  if (s.sidebarWidth) {
    document.documentElement.style.setProperty('--sidebar-w', `${s.sidebarWidth}px`);
  }
}

breeze.onSettings(applySettings);

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

function renderTabs() {
  const existing = new Map(
    [...tabsEl.children].map((el) => [Number(el.dataset.id), el])
  );

  // tabs that belong to a pin live in the pin grid, not the tab list
  const listTabs = state.tabs.filter((t) => !t.pinUrl);

  for (const t of listTabs) {
    let el = existing.get(t.id);
    if (!el) {
      el = document.createElement('div');
      el.className = 'tab';
      el.dataset.id = t.id;

      const fav = document.createElement('span');
      fav.className = 'favicon';
      const title = document.createElement('span');
      title.className = 'title';
      const pinBtn = document.createElement('button');
      pinBtn.className = 'close pin-tab-btn';
      pinBtn.title = 'Pin as app';
      pinBtn.innerHTML = `<svg viewBox="0 0 12 12"><path d="M7.2 1.2 10.8 4.8 9.3 5.1 7.5 6.9 7.2 9.6 5.4 7.8 2.4 10.8 1.2 9.6 4.2 6.6 2.4 4.8 5.1 4.5 6.9 2.7z" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/></svg>`;
      const close = document.createElement('button');
      close.className = 'close';
      close.title = 'Close tab';
      close.innerHTML = xIcon;

      pinBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        breeze.pinTab(t.id);
      });

      el.append(fav, title, pinBtn, close);
      el.addEventListener('click', () => breeze.activateTab(t.id));
      close.addEventListener('click', (e) => {
        e.stopPropagation();
        el.classList.add('closing');
        setTimeout(() => breeze.closeTab(t.id), 150);
      });
      el.addEventListener('auxclick', (e) => {
        if (e.button === 1) breeze.closeTab(t.id);
      });
      el.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        breeze.tabContextMenu(t.id);
      });
      tabsEl.appendChild(el);
    }
    existing.delete(t.id);

    el.classList.toggle('active', t.id === state.activeTabId);
    el.classList.toggle('incognito', !!t.incognito);
    el.querySelector('.title').textContent = t.title;

    const fav = el.querySelector('.favicon');
    if (t.loading) {
      if (!fav.querySelector('.spinner')) {
        fav.dataset.src = '~loading~';
        fav.innerHTML = `<span class="spinner"></span>`;
      }
    } else if (t.incognito && !t.favicon) {
      if (fav.dataset.src !== '~incog~') {
        fav.dataset.src = '~incog~';
        fav.innerHTML = incogIcon;
      }
    } else {
      setFavicon(fav, t.favicon);
    }
  }

  // remove tabs that no longer exist (unless mid-close-animation)
  for (const [, el] of existing) {
    if (!el.classList.contains('closing')) el.remove();
    else setTimeout(() => el.remove(), 200);
  }

  // keep DOM order matching tab order
  listTabs.forEach((t, i) => {
    const el = tabsEl.querySelector(`[data-id="${t.id}"]`);
    if (el && tabsEl.children[i] !== el) tabsEl.insertBefore(el, tabsEl.children[i]);
  });
}

// ---------------------------------------------------------------------------
// Pinned apps
// ---------------------------------------------------------------------------

const pinsEl = $('#pins');

// Keyed reconciliation — pins are only created/removed when the pin set
// changes, so state pushes don't replay the entry animation (no flicker).
function renderPins() {
  const list = state.pins || [];
  const existing = new Map(
    [...pinsEl.children].map((el) => [el.dataset.url, el])
  );

  for (const p of list) {
    let el = existing.get(p.url);
    if (!el) {
      el = document.createElement('div');
      el.className = 'pin';
      el.dataset.url = p.url;
      el.title = p.title;

      if (p.favicon) {
        const img = document.createElement('img');
        img.src = p.favicon;
        img.onerror = () => {
          img.replaceWith(pinLetter(p));
        };
        el.appendChild(img);
      } else {
        el.appendChild(pinLetter(p));
      }

      el.addEventListener('click', () => breeze.openPin(p.url));
      el.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        breeze.pinContextMenu(p.url);
      });
      pinsEl.appendChild(el);
    }
    existing.delete(p.url);

    const tab = state.tabs.find((t) => t.pinUrl === p.url || t.url === p.url);
    el.classList.toggle('open', !!tab);
    el.classList.toggle('active', !!tab && tab.id === state.activeTabId);
  }

  for (const [, el] of existing) el.remove();

  list.forEach((p, i) => {
    const el = pinsEl.querySelector(`[data-url="${CSS.escape(p.url)}"]`);
    if (el && pinsEl.children[i] !== el) pinsEl.insertBefore(el, pinsEl.children[i]);
  });
}

function pinLetter(p) {
  const span = document.createElement('span');
  span.className = 'pin-letter';
  let letter = '•';
  try {
    letter = new URL(p.url).hostname.replace('www.', '')[0].toUpperCase();
  } catch {}
  span.textContent = letter;
  return span;
}

// ---------------------------------------------------------------------------
// State sync
// ---------------------------------------------------------------------------

breeze.onState((s) => {
  state = s;
  renderTabs();
  renderPins();
  const active = s.tabs.find((t) => t.id === s.activeTabId);
  if (active && !addressFocused) address.value = active.url;
  btnBack.disabled = !active?.canGoBack;
  btnForward.disabled = !active?.canGoForward;
  const bookmarked =
    active && active.url && (s.bookmarks || []).some((b) => b.url === active.url);
  btnBookmark.classList.toggle('active', !!bookmarked);
  $('#address-wrap').classList.toggle('incognito', !!active?.incognito);
  if (active?.incognito) address.placeholder = 'Incognito — search privately';
  else address.placeholder = 'Search or enter URL';
});

// ---------------------------------------------------------------------------
// Address bar
// ---------------------------------------------------------------------------

address.addEventListener('focus', () => {
  addressFocused = true;
  address.select();
});
address.addEventListener('blur', () => {
  addressFocused = false;
  setTimeout(hideSuggestions, 120);
  const active = state.tabs.find((t) => t.id === state.activeTabId);
  if (active) address.value = active.url;
});
// ---------------------------------------------------------------------------
// Omnibox suggestions
// ---------------------------------------------------------------------------

const sugEl = $('#suggestions');
const icons = {
  history: `<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M8 4.5V8l2.5 1.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>`,
  bookmark: `<svg viewBox="0 0 16 16"><path d="M4 2.5h8a.5.5 0 0 1 .5.5v10.6a.3.3 0 0 1-.48.24L8 11l-4.02 2.84a.3.3 0 0 1-.48-.24V3a.5.5 0 0 1 .5-.5z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>`,
  search: `<svg viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="m10.5 10.5 3 3" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>`,
};

let sugItems = []; // [{ kind, label, sub, value }]  value = url or search text
let sugIndex = -1;
let sugTimer = null;
let sugSeq = 0;

function hideSuggestions() {
  sugEl.classList.remove('show');
  sugItems = [];
  sugIndex = -1;
}

function renderSuggestions() {
  sugEl.textContent = '';
  if (!sugItems.length) {
    hideSuggestions();
    return;
  }
  sugItems.forEach((item, i) => {
    const el = document.createElement('div');
    el.className = 'sug' + (i === sugIndex ? ' selected' : '');
    el.innerHTML = icons[item.kind];
    const label = document.createElement('span');
    label.className = 's-label';
    label.textContent = item.label;
    el.appendChild(label);
    if (item.sub) {
      const sub = document.createElement('span');
      sub.className = 's-sub';
      sub.textContent = item.sub;
      el.appendChild(sub);
    }
    el.addEventListener('mousedown', (e) => {
      e.preventDefault(); // keep focus so blur doesn't fire first
      acceptSuggestion(item);
    });
    sugEl.appendChild(el);
  });
  sugEl.classList.add('show');
}

function acceptSuggestion(item) {
  breeze.navigate(item.value);
  hideSuggestions();
  address.blur();
}

address.addEventListener('input', () => {
  clearTimeout(sugTimer);
  const q = address.value.trim();
  if (!q) {
    hideSuggestions();
    return;
  }
  sugTimer = setTimeout(async () => {
    const seq = ++sugSeq;
    const r = await breeze.getSuggestions(q);
    if (seq !== sugSeq) return; // stale response, a newer query is in flight
    sugItems = [
      ...r.history.map((h) => ({
        kind: 'history',
        label: h.title || h.url,
        sub: h.url.replace(/^https?:\/\/(www\.)?/, ''),
        value: h.url,
      })),
      ...r.bookmarks.map((b) => ({
        kind: 'bookmark',
        label: b.title,
        sub: b.url.replace(/^https?:\/\/(www\.)?/, ''),
        value: b.url,
      })),
      ...r.web.map((w) => ({ kind: 'search', label: w, value: w })),
    ];
    sugIndex = -1;
    renderSuggestions();
  }, 120);
});

address.addEventListener('keydown', (e) => {
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    if (!sugItems.length) return;
    e.preventDefault();
    const dir = e.key === 'ArrowDown' ? 1 : -1;
    sugIndex = (sugIndex + dir + sugItems.length + 1) % (sugItems.length + 1);
    if (sugIndex === sugItems.length) sugIndex = -1;
    renderSuggestions();
    return;
  }
  if (e.key === 'Enter') {
    if (sugIndex >= 0 && sugItems[sugIndex]) {
      acceptSuggestion(sugItems[sugIndex]);
    } else if (address.value.trim()) {
      breeze.navigate(address.value);
      hideSuggestions();
      address.blur();
    }
  }
  if (e.key === 'Escape') {
    hideSuggestions();
    address.blur();
  }
});

breeze.onFocusAddress(() => {
  address.focus();
  address.select();
});

// ---------------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------------

btnBack.addEventListener('click', () => breeze.goBack());
btnForward.addEventListener('click', () => breeze.goForward());
$('#btn-reload').addEventListener('click', () => breeze.reload());
$('#new-tab-btn').addEventListener('click', () => breeze.newTab());
$('#btn-sidebar').addEventListener('click', () => breeze.toggleSidebar());
$('#settings-btn').addEventListener('click', () => breeze.openSettings());
$('#bookmarks-btn').addEventListener('click', () => breeze.openBookmarks());
$('#downloads-btn').addEventListener('click', () => breeze.openDownloads());
$('#history-btn').addEventListener('click', () => breeze.openHistory());
$('#ai-btn').addEventListener('click', () => breeze.toggleAssistant());

// edge handle: hover to peek (auto-hides when the mouse leaves the sidebar),
// click to dock it for good
const edgeHandle = $('#edge-handle');
let edgeTimer = null;
let peeking = false;

edgeHandle.addEventListener('click', () => {
  clearTimeout(edgeTimer);
  breeze.toggleSidebar();
});
edgeHandle.addEventListener('mouseenter', () => {
  edgeTimer = setTimeout(() => breeze.peekSidebar(), 150);
});
edgeHandle.addEventListener('mouseleave', () => clearTimeout(edgeTimer));

breeze.onSidebarPeek((peek) => {
  peeking = peek;
  document.body.classList.toggle('peeking', peek);
  if (peek) {
    sidebar.classList.remove('hidden');
    document.body.classList.remove('sidebar-hidden');
  } else {
    sidebar.classList.add('hidden');
    document.body.classList.add('sidebar-hidden');
  }
});

// only end the peek when the cursor genuinely exits the expanded sidebar —
// not on stray leave events from child elements or context menus
sidebar.addEventListener('mouseleave', (e) => {
  if (!peeking) return;
  const r = sidebar.getBoundingClientRect();
  const inside =
    e.clientX > r.left + 1 &&
    e.clientX < r.right - 1 &&
    e.clientY > r.top + 1 &&
    e.clientY < r.bottom - 1;
  if (!inside) breeze.endPeek();
});

// ---------------------------------------------------------------------------
// Sidebar resize
// ---------------------------------------------------------------------------

const resizer = $('#sidebar-resizer');
let resizing = false;

resizer.addEventListener('mousedown', (e) => {
  e.preventDefault();
  resizing = true;
  document.body.classList.add('resizing');
});

window.addEventListener('mousemove', (e) => {
  if (!resizing) return;
  const w = Math.min(420, Math.max(220, e.clientX));
  document.documentElement.style.setProperty('--sidebar-w', `${w}px`);
  breeze.setSidebarWidth(w);
});

window.addEventListener('mouseup', () => {
  if (!resizing) return;
  resizing = false;
  document.body.classList.remove('resizing');
  breeze.saveSidebarWidth();
});

// ---------------------------------------------------------------------------
// Downloads activity dot
// ---------------------------------------------------------------------------

breeze.onDownloads((list) => {
  const active = list.some((d) => d.state === 'progressing');
  $('#dl-dot').classList.toggle('active', active);
});
btnBookmark.addEventListener('click', () => {
  btnBookmark.classList.remove('pop');
  void btnBookmark.offsetWidth;
  btnBookmark.classList.add('pop');
  breeze.toggleBookmark();
});

// ---------------------------------------------------------------------------
// Sidebar + theme
// ---------------------------------------------------------------------------

function setSidebarVisible(visible) {
  peeking = false;
  sidebar.classList.toggle('hidden', !visible);
  document.body.classList.toggle('sidebar-hidden', !visible);
}

breeze.onSidebar(setSidebarVisible);

function applyTheme(theme) {
  document.documentElement.classList.toggle('dark', theme === 'dark');
  $('#icon-sun').style.display = theme === 'dark' ? 'none' : 'block';
  $('#icon-moon').style.display = theme === 'dark' ? 'block' : 'none';
}

breeze.onTheme(applyTheme);

$('#theme-btn').addEventListener('click', () => {
  const next = document.documentElement.classList.contains('dark') ? 'light' : 'dark';
  breeze.setTheme(next);
});

// ---------------------------------------------------------------------------
// Assistant
// ---------------------------------------------------------------------------

const assistant = $('#assistant');
const aiMessages = $('#ai-messages');
const aiEmpty = $('#ai-empty');
const aiInput = $('#ai-input');
const aiSend = $('#ai-send');
const aiStatusbar = $('#ai-statusbar');
const aiProgress = $('#ai-progress');
const aiProgressFill = $('#ai-progress-fill');

let aiGenerating = false;
let currentAIMsg = null;

breeze.onAssistant((open) => {
  assistant.classList.toggle('open', open);
  if (open) setTimeout(() => aiInput.focus(), 250);
});

$('#ai-close').addEventListener('click', () => breeze.toggleAssistant());
$('#ai-new-chat').addEventListener('click', () => breeze.aiNewChat());

breeze.onAICleared(() => {
  aiMessages.querySelectorAll('.msg').forEach((m) => m.remove());
  aiEmpty.style.display = '';
});

function addMsg(cls, text) {
  aiEmpty.style.display = 'none';
  const el = document.createElement('div');
  el.className = `msg ${cls}`;
  el.textContent = text;
  aiMessages.appendChild(el);
  aiMessages.scrollTop = aiMessages.scrollHeight;
  return el;
}

function sendAI() {
  const text = aiInput.value.trim();
  if (!text || aiGenerating) return;
  addMsg('user', text);
  aiInput.value = '';
  aiInput.style.height = 'auto';
  currentAIMsg = addMsg('ai thinking', '');
  aiGenerating = true;
  aiSend.classList.add('stop');
  aiSend.title = 'Stop';
  breeze.aiAsk(text, $('#ai-include-page').checked);
}

aiSend.addEventListener('click', () => {
  if (aiGenerating) breeze.aiStop();
  else sendAI();
});

aiInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    sendAI();
  }
});

document.querySelectorAll('.ai-chip').forEach((chip) =>
  chip.addEventListener('click', () => {
    aiInput.value = chip.textContent;
    sendAI();
  })
);

aiInput.addEventListener('input', () => {
  aiInput.style.height = 'auto';
  aiInput.style.height = Math.min(aiInput.scrollHeight, 120) + 'px';
});

breeze.onAIChunk((chunk) => {
  if (!currentAIMsg) currentAIMsg = addMsg('ai', '');
  currentAIMsg.classList.remove('thinking');
  currentAIMsg.textContent += chunk;
  aiMessages.scrollTop = aiMessages.scrollHeight;
});

breeze.onAIDone(() => {
  if (currentAIMsg) {
    currentAIMsg.classList.remove('thinking');
    if (!currentAIMsg.textContent) currentAIMsg.textContent = '(stopped)';
  }
  currentAIMsg = null;
  aiGenerating = false;
  aiSend.classList.remove('stop');
  aiSend.title = 'Send';
});

breeze.onAIStatus((s) => {
  aiProgress.classList.remove('show');
  switch (s.state) {
    case 'downloading': {
      const pct = Math.round((s.progress || 0) * 100);
      aiStatusbar.textContent = `Downloading model (one time) — ${pct}%`;
      aiProgress.classList.add('show');
      aiProgressFill.style.width = `${pct}%`;
      break;
    }
    case 'loading':
      aiStatusbar.textContent = 'Loading model…';
      break;
    case 'generating':
      aiStatusbar.textContent = 'Thinking…';
      break;
    case 'ready':
      aiStatusbar.textContent = 'Llama 3.2 · local · private';
      break;
    case 'error':
      aiStatusbar.textContent = `Error: ${s.message}`;
      if (currentAIMsg) {
        currentAIMsg.classList.remove('thinking');
        currentAIMsg.textContent = `Something went wrong: ${s.message}`;
        currentAIMsg = null;
        aiGenerating = false;
        aiSend.classList.remove('stop');
      }
      break;
  }
});

// ---------------------------------------------------------------------------
// Adblock counter + updates
// ---------------------------------------------------------------------------

breeze.onAdblockCount((n) => {
  const pill = $('#adblock-pill');
  $('#adblock-count').textContent = n.toLocaleString();
  pill.classList.remove('bump');
  void pill.offsetWidth; // restart animation
  pill.classList.add('bump');
});

breeze.onUpdateReady(() => $('#update-toast').classList.add('show'));
$('#update-btn').addEventListener('click', () => breeze.installUpdate());
