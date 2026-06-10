const $ = (s) => document.querySelector(s);

const sidebar = $('#sidebar');
const tabsEl = $('#tabs');
const address = $('#address');
const btnBack = $('#btn-back');
const btnForward = $('#btn-forward');

let state = { tabs: [], activeTabId: null };
let addressFocused = false;

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

breeze.getInit().then(({ theme, sidebarVisible }) => {
  applyTheme(theme);
  sidebar.classList.toggle('hidden', !sidebarVisible);
});

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

const globeIcon = `<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M2 8h12M8 2c-3.5 3.8-3.5 8.2 0 12 3.5-3.8 3.5-8.2 0-12z" fill="none" stroke="currentColor" stroke-width="1.2"/></svg>`;
const xIcon = `<svg viewBox="0 0 10 10"><path d="M1.5 1.5l7 7M8.5 1.5l-7 7" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>`;

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
      el.innerHTML = `
        <span class="favicon"></span>
        <span class="title"></span>
        <button class="close" title="Close tab">${xIcon}</button>`;
      el.addEventListener('click', () => breeze.activateTab(t.id));
      el.querySelector('.close').addEventListener('click', (e) => {
        e.stopPropagation();
        el.classList.add('closing');
        setTimeout(() => breeze.closeTab(t.id), 150);
      });
      el.addEventListener('auxclick', (e) => {
        if (e.button === 1) breeze.closeTab(t.id);
      });
      tabsEl.appendChild(el);
    }
    existing.delete(t.id);

    el.classList.toggle('active', t.id === state.activeTabId);
    el.querySelector('.title').textContent = t.title;

    const fav = el.querySelector('.favicon');
    if (t.loading) {
      fav.innerHTML = `<span class="spinner"></span>`;
    } else if (t.favicon) {
      fav.innerHTML = `<img src="${t.favicon}" onerror="this.outerHTML='${globeIcon.replace(/'/g, '&#39;')}'" />`;
    } else {
      fav.innerHTML = globeIcon;
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

breeze.onState((s) => {
  state = s;
  renderTabs();
  const active = s.tabs.find((t) => t.id === s.activeTabId);
  if (active && !addressFocused) address.value = active.url;
  btnBack.disabled = !active?.canGoBack;
  btnForward.disabled = !active?.canGoForward;
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
// Nav buttons
// ---------------------------------------------------------------------------

btnBack.addEventListener('click', () => breeze.goBack());
btnForward.addEventListener('click', () => breeze.goForward());
$('#btn-reload').addEventListener('click', () => breeze.reload());
$('#new-tab-btn').addEventListener('click', () => breeze.newTab());

// ---------------------------------------------------------------------------
// Sidebar + theme
// ---------------------------------------------------------------------------

breeze.onSidebar((visible) => sidebar.classList.toggle('hidden', !visible));

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
