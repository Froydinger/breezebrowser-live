const $ = (s) => document.querySelector(s);

const sidebar = $('#sidebar');
const tabsEl = $('#tabs');
const bookmarksEl = $('#bookmarks');
const bookmarksSection = $('#bookmarks-section');
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

  for (const t of state.tabs) {
    let el = existing.get(t.id);
    if (!el) {
      el = document.createElement('div');
      el.className = 'tab';
      el.dataset.id = t.id;

      const fav = document.createElement('span');
      fav.className = 'favicon';
      const title = document.createElement('span');
      title.className = 'title';
      const close = document.createElement('button');
      close.className = 'close';
      close.title = 'Close tab';
      close.innerHTML = xIcon;

      el.append(fav, title, close);
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
    el.querySelector('.title').textContent = t.title;

    const fav = el.querySelector('.favicon');
    if (t.loading) {
      if (!fav.querySelector('.spinner')) {
        fav.dataset.src = '~loading~';
        fav.innerHTML = `<span class="spinner"></span>`;
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
  state.tabs.forEach((t, i) => {
    const el = tabsEl.querySelector(`[data-id="${t.id}"]`);
    if (el && tabsEl.children[i] !== el) tabsEl.insertBefore(el, tabsEl.children[i]);
  });
}

// ---------------------------------------------------------------------------
// Bookmarks
// ---------------------------------------------------------------------------

function renderBookmarks() {
  const list = state.bookmarks || [];
  bookmarksSection.classList.toggle('empty', list.length === 0);
  bookmarksEl.textContent = '';
  for (const b of list) {
    const el = document.createElement('div');
    el.className = 'bookmark';
    el.title = b.url;

    const fav = document.createElement('span');
    fav.className = 'favicon';
    try {
      const origin = new URL(b.url).origin;
      setFavicon(fav, `${origin}/favicon.ico`);
    } catch {
      fav.innerHTML = globeIcon;
    }

    const title = document.createElement('span');
    title.className = 'title';
    title.textContent = b.title;

    const close = document.createElement('button');
    close.className = 'close';
    close.title = 'Remove bookmark';
    close.innerHTML = xIcon;
    close.addEventListener('click', (e) => {
      e.stopPropagation();
      breeze.removeBookmark(b.url);
    });

    el.append(fav, title, close);
    el.addEventListener('click', () => breeze.openURL(b.url));
    el.addEventListener('auxclick', (e) => {
      if (e.button === 1) breeze.openURLNewTab(b.url);
    });
    bookmarksEl.appendChild(el);
  }
}

// ---------------------------------------------------------------------------
// Pinned apps
// ---------------------------------------------------------------------------

const pinsEl = $('#pins');

function renderPins() {
  const list = state.pins || [];
  pinsEl.textContent = '';
  const openUrls = new Set(state.tabs.map((t) => t.url));
  for (const p of list) {
    const el = document.createElement('div');
    el.className = 'pin';
    el.title = p.title;
    el.classList.toggle('open', openUrls.has(p.url));

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
  renderBookmarks();
  renderPins();
  const active = s.tabs.find((t) => t.id === s.activeTabId);
  if (active && !addressFocused) address.value = active.url;
  btnBack.disabled = !active?.canGoBack;
  btnForward.disabled = !active?.canGoForward;
  const bookmarked =
    active && active.url && (s.bookmarks || []).some((b) => b.url === active.url);
  btnBookmark.classList.toggle('active', !!bookmarked);
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
  const active = state.tabs.find((t) => t.id === state.activeTabId);
  if (active) address.value = active.url;
});
address.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && address.value.trim()) {
    breeze.navigate(address.value);
    address.blur();
  }
  if (e.key === 'Escape') address.blur();
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
$('#downloads-btn').addEventListener('click', () => breeze.openDownloads());
$('#history-btn').addEventListener('click', () => breeze.openHistory());
$('#ai-btn').addEventListener('click', () => breeze.toggleAssistant());

// edge handle: click or hover briefly to reveal the sidebar
const edgeHandle = $('#edge-handle');
let edgeTimer = null;
edgeHandle.addEventListener('click', () => breeze.toggleSidebar());
edgeHandle.addEventListener('mouseenter', () => {
  edgeTimer = setTimeout(() => breeze.toggleSidebar(), 160);
});
edgeHandle.addEventListener('mouseleave', () => clearTimeout(edgeTimer));

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
