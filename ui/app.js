const $ = (s) => document.querySelector(s);

const sidebar = $('#sidebar');
const tabsEl = $('#tabs');
const address = $('#address');
const btnBack = $('#btn-back');
const btnForward = $('#btn-forward');
const btnBookmark = $('#btn-bookmark');

let state = { tabs: [], activeTabId: null, bookmarks: [] };
let addressFocused = false;

// While not editing, show just the site (hostname) — hide the path/query/slug.
// The full URL comes back the moment the bar is focused for editing.
function collapseUrl(url) {
  if (!url) return '';
  try {
    const u = new URL(url);
    if (u.protocol === 'file:') return '';
    return u.hostname.replace(/^www\./, '');
  } catch {
    return url;
  }
}

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
  if (settings && !settings.onboarded) startOnboarding();
});

// ---------------------------------------------------------------------------
// First-run onboarding
// ---------------------------------------------------------------------------

function startOnboarding() {
  const ob = $('#onboard');
  const steps = [...ob.querySelectorAll('.onboard-step')];
  const dotsWrap = ob.querySelector('.onboard-dots');
  dotsWrap.innerHTML = steps.map(() => '<span class="dot"></span>').join('');
  const dots = [...dotsWrap.children];
  let i = 0;

  const show = (n) => {
    steps.forEach((s, idx) => (s.hidden = idx !== n));
    dots.forEach((d, idx) => d.classList.toggle('on', idx === n));
    const inp = steps[n].querySelector('input');
    if (inp) setTimeout(() => inp.focus(), 300);
  };

  // "Get a key" links open in a real tab (these are buttons, not <a href>)
  ob.querySelectorAll('.onboard-keylink').forEach((a) =>
    a.addEventListener('click', () => breeze.openURLNewTab(a.dataset.url))
  );

  breeze.onboardingActive(true); // detach page view so the dialog is visible
  ob.classList.remove('hidden');
  requestAnimationFrame(() => ob.classList.add('visible'));
  show(0);

  ob.querySelectorAll('.onboard-next').forEach((btn) =>
    btn.addEventListener('click', () => {
      if (btn.id === 'onboard-finish') {
        const name = $('#onboard-name').value.trim();
        if (name) breeze.setSetting('userName', name);
        finishOnboarding();
        return;
      }
      i = Math.min(steps.length - 1, i + 1);
      show(i);
    })
  );

  function finishOnboarding() {
    breeze.setSetting('onboarded', true);
    breeze.onboardingActive(false); // re-attach the page view
    ob.classList.remove('visible');
    setTimeout(() => ob.classList.add('hidden'), 450);
  }
}

let soundsOn = true; // mirrors the "Breeze notification sounds" setting
function applySettings(s) {
  soundsOn = s.notificationSounds !== false;
  if (s.accent) document.documentElement.style.setProperty('--accent', s.accent);
  if (s.sidebarWidth) {
    document.documentElement.style.setProperty('--sidebar-w', `${s.sidebarWidth}px`);
  }
  applyUrlBarMode(s.urlBarPosition || 'top');
  if (s.theme) {
    themePref = s.theme;
    updateThemeIcon();
  }
  const pinSizes = { small: '36px', medium: '44px', large: '52px' };
  document.documentElement.style.setProperty(
    '--pin-min',
    pinSizes[s.pinSize] || pinSizes.large
  );
}

// The address bar + nav buttons are single DOM nodes that physically move
// between the sidebar and the top bar, so all their logic stays in one place.
function applyUrlBarMode(mode) {
  const topbar = $('#topbar');
  const navRow = $('#nav-row');
  const addressWrap = $('#address-wrap');
  const back = $('#btn-back');
  const fwd = $('#btn-forward');
  const reload = $('#btn-reload');
  if (mode === 'top') {
    topbar.append(back, fwd, reload, addressWrap);
    document.body.classList.add('urlbar-top');
  } else {
    const spacer = navRow.querySelector('.nav-spacer');
    navRow.insertBefore(back, spacer);
    navRow.insertBefore(fwd, spacer);
    navRow.insertBefore(reload, spacer);
    sidebar.insertBefore(addressWrap, $('#pins'));
    document.body.classList.remove('urlbar-top');
  }
}

breeze.onSettings(applySettings);

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

let dragTabId = null;

function renderTabs() {
  if (dragTabId) return; // don't fight the user's drag mid-flight
  const existing = new Map(
    [...tabsEl.children].map((el) => [Number(el.dataset.id), el])
  );

  // tabs that belong to a pin or a group render elsewhere, not the tab list
  const listTabs = state.tabs.filter((t) => !t.pinUrl && !t.groupEid);

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
      const rocket = document.createElement('span');
      rocket.className = 'perf-badge';
      rocket.textContent = '🚀';
      rocket.title = 'Performance Mode on';
      const close = document.createElement('button');
      close.className = 'close';
      close.title = 'Close tab';
      close.innerHTML = xIcon;

      pinBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        breeze.pinTab(t.id);
      });

      el.append(fav, title, rocket, pinBtn, close);
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

      // drag to reorder within the tab list
      el.draggable = true;
      el.addEventListener('dragstart', (e) => {
        dragTabId = t.id;
        el.classList.add('dragging');
        e.dataTransfer.effectAllowed = 'move';
      });
      el.addEventListener('dragend', () => {
        dragTabId = null;
        el.classList.remove('dragging');
        breeze.reorderTabs(
          [...tabsEl.children].map((c) => Number(c.dataset.id))
        );
      });
      el.addEventListener('dragover', (e) => {
        e.preventDefault();
        if (!dragTabId || dragTabId === t.id) return;
        const dragging = tabsEl.querySelector('.tab.dragging');
        if (!dragging) return;
        const r = el.getBoundingClientRect();
        const after = e.clientY > r.top + r.height / 2;
        tabsEl.insertBefore(dragging, after ? el.nextSibling : el);
      });

      tabsEl.appendChild(el);
    }
    existing.delete(t.id);

    el.classList.toggle('active', t.id === state.activeTabId || t.id === state.splitTabId);
    el.classList.toggle('split', t.id === state.splitTabId);
    el.classList.toggle('incognito', !!t.incognito);
    el.classList.toggle('asleep', !!t.sleeping);
    el.classList.toggle('perf', !!t.perfMode);
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
let dragPinUrl = null;

// Keyed reconciliation — pins are only created/removed when the pin set
// changes, so state pushes don't replay the entry animation (no flicker).
function renderPins() {
  if (dragPinUrl) return; // don't fight the user's drag mid-flight
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

      // drag to rearrange
      el.draggable = true;
      el.addEventListener('dragstart', (e) => {
        dragPinUrl = p.url;
        el.classList.add('dragging');
        e.dataTransfer.effectAllowed = 'move';
      });
      el.addEventListener('dragend', () => {
        dragPinUrl = null;
        el.classList.remove('dragging');
        breeze.reorderPins([...pinsEl.children].map((c) => c.dataset.url));
      });
      el.addEventListener('dragover', (e) => {
        e.preventDefault();
        if (!dragPinUrl || dragPinUrl === el.dataset.url) return;
        const dragging = pinsEl.querySelector('.pin.dragging');
        if (!dragging) return;
        const r = el.getBoundingClientRect();
        const after = e.clientX > r.left + r.width / 2;
        pinsEl.insertBefore(dragging, after ? el.nextSibling : el);
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
// Tab groups
// ---------------------------------------------------------------------------

const groupsEl = $('#groups');

// Keyed reconciliation: group sections and entry rows persist across state
// pushes and update in place — no teardown, no entry-animation replay.
function buildGroupSection(g) {
  const section = document.createElement('div');
  section.className = 'group';
  section.dataset.gid = g.id;

  const header = document.createElement('div');
  header.className = 'group-header';
  header.innerHTML =
    `<span class="group-carrot"><svg viewBox="0 0 12 12"><path d="M4 2.5 8 6l-4 3.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg></span>` +
    `<span class="group-dot"></span><span class="group-name"></span><span class="group-count"></span>`;
  // whole header toggles collapse; rename + delete live in the right-click menu
  header.addEventListener('click', () => breeze.toggleGroupCollapse(g.id));
  header.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    breeze.groupHeaderMenu(g.id);
  });
  section.appendChild(header);
  return section;
}

function buildGroupEntry(gid, eid) {
  const el = document.createElement('div');
  el.className = 'tab group-entry';
  el.dataset.eid = eid;

  const fav = document.createElement('span');
  fav.className = 'favicon';
  const title = document.createElement('span');
  title.className = 'title';
  const close = document.createElement('button');
  close.className = 'close';
  close.innerHTML = xIcon;
  close.addEventListener('click', (e) => {
    e.stopPropagation();
    breeze.groupEntryMenu(gid, eid);
  });

  el.append(fav, title, close);
  el.addEventListener('click', () => breeze.openGroupEntry(gid, eid));
  el.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    breeze.groupEntryMenu(gid, eid);
  });
  return el;
}

function renderGroups() {
  const list = state.groups || [];
  const liveByEid = new Map(
    state.tabs.filter((t) => t.groupEid).map((t) => [t.groupEid, t])
  );

  const sections = new Map(
    [...groupsEl.children].map((el) => [Number(el.dataset.gid), el])
  );

  list.forEach((g, gi) => {
    let section = sections.get(g.id);
    if (!section) section = buildGroupSection(g);
    sections.delete(g.id);

    const nameEl = section.querySelector('.group-name');
    // don't clobber an in-progress inline rename
    if (nameEl.contentEditable !== 'true' && nameEl.textContent !== g.name) {
      nameEl.textContent = g.name;
    }

    // collapsed: show only OPEN tabs (or just the header if none are open).
    // Groups are collapsed by DEFAULT (undefined === collapsed); only an
    // explicit `collapsed:false` expands them.
    const collapsed = g.collapsed !== false;
    section.classList.toggle('collapsed', collapsed);
    const openCount = g.entries.filter((e) => liveByEid.has(e.eid)).length;
    const visibleEntries = collapsed
      ? g.entries.filter((e) => liveByEid.has(e.eid))
      : g.entries;
    const countEl = section.querySelector('.group-count');
    countEl.textContent = collapsed && g.entries.length ? String(g.entries.length) : '';

    const rows = new Map(
      [...section.querySelectorAll('.group-entry')].map((el) => [
        Number(el.dataset.eid),
        el,
      ])
    );

    visibleEntries.forEach((entry, i) => {
      let el = rows.get(entry.eid);
      if (!el) el = buildGroupEntry(g.id, entry.eid);
      rows.delete(entry.eid);

      const live = liveByEid.get(entry.eid);
      el.classList.toggle('asleep', !live || !!live.sleeping);
      el.classList.toggle('active', !!live && live.id === state.activeTabId);

      const titleEl = el.querySelector('.title');
      const nextTitle = (live && live.title) || entry.title;
      if (titleEl.textContent !== nextTitle) titleEl.textContent = nextTitle;

      el.querySelector('.close').title = live
        ? 'Close (stays in group)'
        : 'Remove from group';

      const fav = el.querySelector('.favicon');
      if (live?.loading) {
        if (!fav.querySelector('.spinner')) {
          fav.dataset.src = '~loading~';
          fav.innerHTML = `<span class="spinner"></span>`;
        }
      } else {
        setFavicon(fav, (live && live.favicon) || entry.favicon);
      }

      // header is child 0, entries start at 1
      const want = section.children[i + 1];
      if (want !== el) section.insertBefore(el, want || null);
    });

    for (const [, el] of rows) el.remove();

    if (groupsEl.children[gi] !== section) {
      groupsEl.insertBefore(section, groupsEl.children[gi] || null);
    }
  });

  for (const [, el] of sections) el.remove();
}

function startRename(gid) {
  const name = groupsEl.querySelector(`[data-gid="${gid}"] .group-name`);
  if (!name) return;
  name.contentEditable = 'true';
  name.focus();
  document.execCommand('selectAll');
  const done = () => {
    name.contentEditable = 'false';
    breeze.renameGroup(gid, name.textContent.trim());
  };
  name.addEventListener('blur', done, { once: true });
  name.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === 'Escape') {
      e.preventDefault();
      name.blur();
    }
  });
}

breeze.onRenameGroupStart((gid) => setTimeout(() => startRename(gid), 80));

// ---------------------------------------------------------------------------
// State sync
// ---------------------------------------------------------------------------

breeze.onState((s) => {
  state = s;
  renderTabs();
  renderPins();
  renderGroups();
  const active = s.tabs.find((t) => t.id === s.activeTabId);
  if (active && !addressFocused) address.value = collapseUrl(active.url);
  // keep the split-view per-pane bars in sync with navigation
  if (splitBarGeom) { fillSplitBar(splitBarL); fillSplitBar(splitBarR); }
  btnBack.disabled = !active?.canGoBack;
  btnForward.disabled = !active?.canGoForward;
  const bookmarked =
    active && active.url && (s.bookmarks || []).some((b) => b.url === active.url);
  btnBookmark.classList.toggle('active', !!bookmarked);
  // notification bell: only for sites that use notifications; reflects state
  const notifBtn = $('#btn-notif');
  if (active && active.notifSite) {
    notifBtn.hidden = false;
    notifBtn.classList.toggle('off', !active.notifOn);
    notifBtn.title = active.notifOn
      ? 'Notifications on for this site — click to mute'
      : 'Notifications muted for this site — click to allow';
  } else {
    notifBtn.hidden = true;
  }
  document.body.classList.toggle('page-loading', !!active?.loading);
  $('#address-wrap').classList.toggle('incognito', !!active?.incognito);
  addrIncognito = !!active?.incognito;
  updateAddressPlaceholder();
});

// Shorten the placeholder to just "Search" when the bar is too narrow to show
// the full hint, instead of letting the text clip mid-word.
let addrIncognito = false;
function updateAddressPlaceholder() {
  const narrow = address.clientWidth < 150;
  address.placeholder = narrow
    ? 'Search'
    : addrIncognito
    ? 'Incognito — search privately'
    : 'Search or enter URL';
}
try { new ResizeObserver(updateAddressPlaceholder).observe(address); } catch {}

// ---------------------------------------------------------------------------
// Address bar
// ---------------------------------------------------------------------------

address.addEventListener('focus', () => {
  addressFocused = true;
  // reveal the full URL (with path/slug) for editing
  const active = state.tabs.find((t) => t.id === state.activeTabId);
  if (active && active.url) address.value = active.url;
  address.select();
});
// As soon as the user types in the address bar, halt the page load — so a tab
// stuck reloading (broken URL / redirect loop) can't keep overwriting things
// while you try to fix the URL.
address.addEventListener('input', () => breeze.stopLoading());
address.addEventListener('blur', () => {
  addressFocused = false;
  setTimeout(hideSuggestions, 120);
  const active = state.tabs.find((t) => t.id === state.activeTabId);
  if (active) address.value = collapseUrl(active.url);
});
// ---------------------------------------------------------------------------
// Omnibox suggestions
// ---------------------------------------------------------------------------

const sugEl = $('#suggestions');
const icons = {
  tab: `<svg viewBox="0 0 16 16"><rect x="2" y="3" width="12" height="10" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="m6 8 2 2 3-3.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
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
  breeze.omniboxOverlay(0); // let the page view return to full size
}

// In top-bar mode the native page view covers the dropdown, so tell main how
// far to push the view down to clear it.
function syncOmniboxOverlay() {
  if (document.body.classList.contains('urlbar-top') && sugEl.classList.contains('show')) {
    const r = sugEl.getBoundingClientRect();
    breeze.omniboxOverlay(r.bottom - 52);
  } else {
    breeze.omniboxOverlay(0);
  }
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
  syncOmniboxOverlay();
}

function acceptSuggestion(item) {
  if (item.kind === 'tab') breeze.activateTab(item.tabId);
  else breeze.navigate(item.value);
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
      ...(r.openTabs || []).map((t) => ({
        kind: 'tab',
        label: t.title,
        sub: 'Switch to tab',
        value: t.url,
        tabId: t.id,
      })),
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
$('#btn-newtab').addEventListener('click', () => breeze.newTab());
$('#btn-sidebar').addEventListener('click', () => breeze.toggleSidebar());
$('#settings-btn').addEventListener('click', () => breeze.openSettings());
$('#bookmarks-btn').addEventListener('click', () => breeze.openBookmarks());
$('#downloads-btn').addEventListener('click', () => breeze.openDownloads());
$('#history-btn').addEventListener('click', () => breeze.openHistory());
$('#ai-settings-btn').addEventListener('click', () => breeze.openSettings('ai'));
$('#breeze-corner').addEventListener('click', () => breeze.toggleAssistant());
breeze.onFullscreen((on) => document.body.classList.toggle('app-fullscreen', on));
breeze.onCornerPeek((on) => document.body.classList.toggle('corner-peek', on));
$('#btn-clearcache').addEventListener('click', () => {
  const btn = $('#btn-clearcache');
  btn.classList.add('pop');
  setTimeout(() => btn.classList.remove('pop'), 300);
  breeze.clearTabData();
});
$('#btn-notif').addEventListener('click', () => {
  const active = state.tabs.find((t) => t.id === state.activeTabId);
  if (!active || !active.url) return;
  let origin;
  try { origin = new URL(active.url).origin; } catch { return; }
  const btn = $('#btn-notif');
  btn.classList.add('pop');
  setTimeout(() => btn.classList.remove('pop'), 300);
  breeze.toggleSiteNotif(origin);
});

// adblock pill → little popover with the running count
const adblockPop = $('#adblock-pop');
let adblockPopTimer = null;
$('#adblock-pill').addEventListener('click', (e) => {
  e.stopPropagation();
  $('#adblock-pop-count').textContent = $('#adblock-count').textContent;
  adblockPop.classList.add('show');
  clearTimeout(adblockPopTimer);
  adblockPopTimer = setTimeout(() => adblockPop.classList.remove('show'), 2600);
});
document.addEventListener('click', () => adblockPop.classList.remove('show'));

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
  edgeTimer = setTimeout(() => breeze.peekSidebar(), 70);
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

// current page URL for copy/share (empty on internal pages like the new tab)
function activeUrl() {
  const active = state.tabs?.find((t) => t.id === state.activeTabId);
  return active && active.url ? active.url : '';
}

const btnCopyLink = $('#btn-copylink');
btnCopyLink.addEventListener('click', () => {
  const url = activeUrl();
  if (!url) return;
  breeze.copyText(url);
  btnCopyLink.classList.add('copied');
  setTimeout(() => btnCopyLink.classList.remove('copied'), 1100);
});

const btnShare = $('#btn-share');
btnShare.addEventListener('click', () => {
  const url = activeUrl();
  if (!url) return;
  btnShare.classList.remove('pop');
  void btnShare.offsetWidth;
  btnShare.classList.add('pop');
  breeze.shareUrl(url);
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

let themePref = 'light'; // 'light' | 'dark' | 'system'

function applyTheme(theme) {
  // `theme` is the effective light/dark from main
  document.documentElement.classList.toggle('dark', theme === 'dark');
  updateThemeIcon();
}

function updateThemeIcon() {
  $('#icon-sun').style.display = themePref === 'light' ? 'block' : 'none';
  $('#icon-moon').style.display = themePref === 'dark' ? 'block' : 'none';
  $('#icon-system').style.display = themePref === 'system' ? 'block' : 'none';
}

breeze.onTheme(applyTheme);

$('#theme-btn').addEventListener('click', () => {
  themePref = themePref === 'light' ? 'dark' : themePref === 'dark' ? 'system' : 'light';
  updateThemeIcon();
  breeze.setTheme(themePref);
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
  document.body.classList.toggle('assistant-open', open);
  if (open) setTimeout(() => aiInput.focus(), 250);
  else clearSelectionChip(); // drop any active selection when the panel closes
});

$('#ai-close').addEventListener('click', () => breeze.toggleAssistant());

// Fullscreen ⇄ dock toggle for the assistant. Fullscreen isolates the chat
// (the main process detaches page views + cuts page-reading context).
let aiIsFullscreen = false;
const aiFsBtn = $('#ai-fullscreen-btn');
aiFsBtn.addEventListener('click', () => breeze.aiFullscreen(!aiIsFullscreen));
breeze.onAIFullscreen((on) => {
  aiIsFullscreen = !!on;
  assistant.classList.toggle('fullscreen', aiIsFullscreen);
  document.body.classList.toggle('ai-fullscreen', aiIsFullscreen);
  aiFsBtn.title = aiIsFullscreen ? 'Dock to sidebar' : 'Fullscreen chat';
  if (aiIsFullscreen) setTimeout(() => aiInput.focus(), 60);
});

// New-tab Dia input asked the assistant something — submit it here.
breeze.onAISubmit((text) => {
  if (!text) return;
  aiInput.value = text;
  sendAI();
});

// ---------------------------------------------------------------------------
// Local chat history
// ---------------------------------------------------------------------------

let chatId = Date.now();
let chatMessages = []; // [{role:'user'|'ai'|'image', text|src}]
const aiChats = $('#ai-chats');

function chatTitle() {
  const firstUser = chatMessages.find((m) => m.role === 'user');
  return firstUser ? firstUser.text.slice(0, 48) : 'New chat';
}
function persistChat() {
  if (!chatMessages.length) return;
  breeze.chatSave({ id: chatId, title: chatTitle(), messages: chatMessages });
}
function startNewChat() {
  chatId = Date.now();
  chatMessages = [];
  aiMessages.querySelectorAll('.msg, .ai-image-msg').forEach((m) => m.remove());
  aiEmpty.style.display = '';
  clearActivityChips(false);
  breeze.aiNewChat();
  aiChats.classList.add('hidden');
}
function renderLoadedChat(messages) {
  aiMessages.querySelectorAll('.msg, .ai-image-msg').forEach((m) => m.remove());
  aiEmpty.style.display = 'none';
  for (const m of messages) {
    if (m.role === 'image') {
      continue; // image generation was removed; skip any legacy saved images
    } else if (m.role === 'search') {
      addSearchChip(m);
    } else {
      addMsg(m.role === 'user' ? 'user' : 'ai', m.text);
    }
  }
  aiMessages.scrollTop = aiMessages.scrollHeight;
}

async function renderChatList() {
  const list = await breeze.chatList();
  const el = $('#ai-chats-list');
  el.textContent = '';
  if (!list.length) {
    el.innerHTML = '<div class="ai-chat-empty">No saved chats yet.</div>';
    return;
  }
  for (const c of list) {
    const row = document.createElement('div');
    row.className = 'ai-chat-row' + (c.id === chatId ? ' active' : '');
    const t = document.createElement('span');
    t.className = 'ai-chat-title';
    t.textContent = c.title;
    const del = document.createElement('button');
    del.className = 'ai-chat-del';
    del.textContent = '✕';
    del.title = 'Delete chat';
    del.addEventListener('click', (e) => {
      e.stopPropagation();
      breeze.chatDelete(c.id);
    });
    row.append(t, del);
    row.addEventListener('click', async () => {
      const data = await breeze.chatLoad(c.id);
      if (!data) return;
      chatId = c.id;
      chatMessages = data.messages.slice();
      renderLoadedChat(chatMessages);
      aiChats.classList.add('hidden');
    });
    el.appendChild(row);
  }
}

$('#ai-history').addEventListener('click', () => {
  const showing = aiChats.classList.toggle('hidden');
  if (!showing) renderChatList();
});
$('#ai-new-chat').addEventListener('click', startNewChat);
breeze.onChatsChanged(() => {
  if (!aiChats.classList.contains('hidden')) renderChatList();
});

breeze.onAICleared(() => {
  aiMessages.querySelectorAll('.msg').forEach((m) => m.remove());
  aiEmpty.style.display = '';
});

// Lightweight, SAFE markdown → HTML: escapes everything first, then adds
// **bold**, `code`, [text](url), and bare URLs as clickable links.
function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])
  );
}
function renderMarkdown(text) {
  let h = escapeHtml(text);
  // [label](url)
  h = h.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g,
    (_m, label, url) => `<a class="ai-link" data-url="${url}">${label}</a>`);
  // bare URLs (not already inside an anchor)
  h = h.replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g,
    (_m, pre, url) => `${pre}<a class="ai-link" data-url="${url}">${url}</a>`);
  h = h.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  h = h.replace(/`([^`]+)`/g, '<code>$1</code>');
  h = h.replace(/\n/g, '<br>');
  return h;
}

function setMsgText(el, text) {
  el.dataset.raw = text;
  if (el.classList.contains('user')) {
    el.textContent = text;
  } else {
    // backstop: never render leaked chat-template / tool-call artifacts if the
    // model role-plays the transcript despite the stop triggers
    const clean = text.replace(/<\/?tool_call>[\s\S]*$/i, '').replace(/<\|im_(start|end)\|>[\s\S]*$/i, '');
    el.innerHTML = renderMarkdown(clean);
  }
}

function addMsg(cls, text) {
  aiEmpty.style.display = 'none';
  const el = document.createElement('div');
  el.className = `msg ${cls}`;
  setMsgText(el, text);
  aiMessages.appendChild(el);
  aiMessages.scrollTop = aiMessages.scrollHeight;
  return el;
}

// open links in AI chat in a new tab (delegated, works for streamed content)
aiMessages.addEventListener('click', (e) => {
  const a = e.target.closest('a.ai-link');
  if (a && a.dataset.url) {
    e.preventDefault();
    breeze.openURLNewTab(a.dataset.url);
  }
});

// Transient activity chips — they show what the AI is doing FOR THE CURRENT
// request, then fade away when it's done. They never pile up across the chat.
const aiActivity = $('#ai-activity');
function clearActivityChips(fade) {
  if (fade) {
    aiActivity.querySelectorAll('.ai-tool-chip').forEach((c) => c.classList.add('fade'));
    setTimeout(() => { aiActivity.textContent = ''; }, 320);
  } else {
    aiActivity.textContent = '';
  }
}
function addToolChip(label) {
  // de-dupe: don't add the same activity twice in one request
  if ([...aiActivity.children].some((c) => c.textContent === label)) return;
  const el = document.createElement('div');
  el.className = 'ai-tool-chip';
  el.textContent = label;
  aiActivity.appendChild(el);
}

let activeSelection = ''; // page text the user highlighted while panel is open

function sendAI() {
  const text = aiInput.value.trim();
  if (!text || aiGenerating) return;
  if (!aiReady) {
    // Model isn't warm yet — don't fire into a cold model (it just spins).
    // Hold the message and send it automatically the instant it's ready.
    pendingSidebarMsg = text;
    aiInput.value = '';
    aiInput.style.height = 'auto';
    aiStatusbar.textContent = 'Warming up the model — your message will send the moment it\'s ready…';
    // In case it became ready just now and we missed the broadcast, re-check.
    breeze.aiReady().then((r) => {
      if (r && pendingSidebarMsg) {
        aiReady = true;
        const m = pendingSidebarMsg;
        pendingSidebarMsg = null;
        aiInput.value = m;
        sendAI();
      }
    });
    return;
  }
  addMsg('user', text);
  chatMessages.push({ role: 'user', text });
  aiInput.value = '';
  aiInput.style.height = 'auto';
  currentAIMsg = addMsg('ai thinking', '');
  _repliedTone = false;
  aiGenerating = true;
  aiSend.classList.add('stop');
  aiSend.title = 'Stop';
  clearActivityChips(false); // fresh activity for this request
  breeze.aiAsk({ text, selection: activeSelection });
  clearSelectionChip();
}

// optional web lookup — the AI cross-references live sources when enabled
// Web search and image generation are handled by the model itself now (it calls
// the web_search tool from plain language) — no toggles.

// active selection chip
const selChip = $('#ai-selection-chip');
function clearSelectionChip() {
  activeSelection = '';
  selChip.classList.remove('show');
}
breeze.onPageSelection((text) => {
  if (!assistant.classList.contains('open')) return; // only when panel open
  activeSelection = text || '';
  if (activeSelection) {
    selChip.querySelector('.sel-text').textContent = activeSelection;
    selChip.classList.add('show');
  } else {
    selChip.classList.remove('show');
  }
});
$('#sel-clear').addEventListener('click', clearSelectionChip);
$('#sel-search').addEventListener('click', () => {
  if (activeSelection) breeze.navigate(activeSelection);
});

breeze.onAITool((t) => addToolChip(t.label));

// Persistent, clickable record of an agentic web search, inline in the chat.
// Clicking it re-runs the exact search in a new tab (no caching needed).
function addSearchChip(s) {
  aiEmpty.style.display = 'none';
  const chip = document.createElement('div');
  chip.className = 'msg ai-search-chip';
  chip.title = 'Open this search again';
  chip.innerHTML =
    '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="m10.5 10.5 3 3" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>';
  const txt = document.createElement('span');
  txt.className = 'asc-text';
  txt.textContent = `Searched ${s.engine || 'the web'}: ${s.query}`;
  chip.appendChild(txt);
  chip.addEventListener('click', () => breeze.openURLNewTab(s.url));
  aiMessages.appendChild(chip);
  aiMessages.scrollTop = aiMessages.scrollHeight;
}

breeze.onAISearch((s) => {
  addSearchChip(s);
  chatMessages.push({ role: 'search', query: s.query, url: s.url, engine: s.engine });
  persistChat();
});

// Privacy consent: before any web search leaves the device, the main process
// asks here. Show an inline card with the disclosure + Search/Skip; the click
// replies and the AI continues (search on Search, local-only on Skip).
breeze.onAIWebConsent(() => {
  if (currentAIMsg) currentAIMsg.classList.remove('thinking'); // pause the dots

  const card = document.createElement('div');
  card.className = 'ai-web-consent';
  card.innerHTML = `
    <div class="awc-head">
      <svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M1.5 8h13M8 1.5c2 2 2 11 0 13M8 1.5c-2 2-2 11 0 13" fill="none" stroke="currentColor" stroke-width="1.2"/></svg>
      <span>Search the web?</span>
    </div>
    <p>This sends your query to our search provider, so it leaves your
       device. Breeze doesn't collect, store, or share what you search —
       and nothing is sent until you choose Search.</p>
    <div class="awc-actions">
      <button class="awc-skip" type="button">Skip · answer locally</button>
      <button class="awc-go" type="button">Search the web</button>
    </div>`;
  aiMessages.appendChild(card);
  aiMessages.scrollTop = aiMessages.scrollHeight;

  let replied = false;
  const reply = (ok) => {
    if (replied) return;
    replied = true;
    card.remove();
    if (currentAIMsg) currentAIMsg.classList.add('thinking');
    breeze.aiWebConsent(ok);
  };
  card.querySelector('.awc-go').addEventListener('click', () => reply(true));
  card.querySelector('.awc-skip').addEventListener('click', () => reply(false));
});

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

// A soft, deep tone the moment the assistant starts replying.
let _toneCtx = null;
let _repliedTone = false;
function playReplyTone() {
  if (!soundsOn) return; // respect the notification-sounds setting
  try {
    _toneCtx = _toneCtx || new (window.AudioContext || window.webkitAudioContext)();
    const ctx = _toneCtx;
    if (ctx.state === 'suspended') ctx.resume();
    const t0 = ctx.currentTime;
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    o.type = 'sine';
    o.frequency.setValueAtTime(180, t0);
    o.frequency.exponentialRampToValueAtTime(120, t0 + 0.28);
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.exponentialRampToValueAtTime(0.13, t0 + 0.02);
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.5);
    o.connect(g); g.connect(ctx.destination);
    o.start(t0); o.stop(t0 + 0.52);
  } catch {}
}

breeze.onAIChunk((chunk) => {
  if (!currentAIMsg) currentAIMsg = addMsg('ai', '');
  if (!_repliedTone) { _repliedTone = true; playReplyTone(); }
  currentAIMsg.classList.remove('thinking');
  setMsgText(currentAIMsg, (currentAIMsg.dataset.raw || '') + chunk);
  aiMessages.scrollTop = aiMessages.scrollHeight;
});

// Context-overflow recovery REPLACES the half-streamed message (no splicing).
breeze.onAIReplace((text) => {
  if (!currentAIMsg) currentAIMsg = addMsg('ai', '');
  currentAIMsg.classList.remove('thinking');
  setMsgText(currentAIMsg, text);
  aiMessages.scrollTop = aiMessages.scrollHeight;
});

// Model readiness — never let a message fire into a cold model (it just spins).
let aiReady = false;
let pendingSidebarMsg = null;
breeze.aiReady().then((r) => { aiReady = r; }).catch(() => {});
breeze.onAIReady(() => {
  aiReady = true;
  if (pendingSidebarMsg) {
    const m = pendingSidebarMsg;
    pendingSidebarMsg = null;
    aiInput.value = m;
    sendAI();
  }
});

breeze.onAIDone(() => {
  if (currentAIMsg) {
    currentAIMsg.classList.remove('thinking');
    if (!currentAIMsg.dataset.raw) setMsgText(currentAIMsg, '(stopped)');
    if (currentAIMsg.dataset.raw) {
      chatMessages.push({ role: 'ai', text: currentAIMsg.dataset.raw });
    }
  }
  currentAIMsg = null;
  aiGenerating = false;
  aiSend.classList.remove('stop');
  aiSend.title = 'Send';
  clearActivityChips(true); // activity finished — fade the chips out
  persistChat();
});

breeze.onAIStatus((s) => {
  aiProgress.classList.remove('show');
  switch (s.state) {
    case 'downloading': {
      aiReady = false;
      const pct = Math.round((s.progress || 0) * 100);
      aiStatusbar.textContent = `Getting ready — downloading model (one time) ${pct}%`;
      aiProgress.classList.add('show');
      aiProgressFill.style.width = `${pct}%`;
      break;
    }
    case 'loading':
      aiReady = false;
      aiStatusbar.textContent = 'Almost ready — warming up the model…';
      aiProgress.classList.add('show');
      aiProgressFill.style.width = '100%';
      break;
    case 'awaiting-web-consent':
      aiStatusbar.textContent = 'Waiting for your OK to search…';
      break;
    case 'searching':
      aiStatusbar.textContent = 'Searching the web…';
      break;
    case 'generating':
      aiStatusbar.textContent = 'Thinking…';
      break;
    case 'ready':
      aiReady = true;
      if (pendingSidebarMsg) {
        const m = pendingSidebarMsg;
        pendingSidebarMsg = null;
        aiInput.value = m;
        sendAI();
        break;
      }
      aiStatusbar.textContent = 'Breeze AI · GPT-5.4-mini';
      break;
    case 'error':
      aiStatusbar.textContent = `Error: ${s.message}`;
      if (currentAIMsg) {
        currentAIMsg.classList.remove('thinking');
        setMsgText(currentAIMsg, `Something went wrong: ${s.message}`);
        currentAIMsg = null;
        aiGenerating = false;
        aiSend.classList.remove('stop');
      }
      break;
  }
});

// ---------------------------------------------------------------------------
// Now Playing
// ---------------------------------------------------------------------------

const npEl = $('#now-playing');
let npTabId = null;

breeze.onNowPlaying((p) => {
  npEl.classList.toggle('show', !!p);
  if (!p) {
    npTabId = null;
    return;
  }
  npTabId = p.id;
  npEl.classList.toggle('playing', p.playing);
  npEl.querySelector('.np-title').textContent = p.title;
  setFavicon(npEl.querySelector('.np-favicon'), p.favicon);
  $('#np-icon-pause').style.display = p.playing ? 'block' : 'none';
  $('#np-icon-play').style.display = p.playing ? 'none' : 'block';
});

$('#np-play').addEventListener('click', () => npTabId && breeze.mediaToggle(npTabId));
$('#np-pip').addEventListener('click', () => npTabId && breeze.mediaPiP(npTabId));
$('#np-back').addEventListener('click', () => npTabId && breeze.mediaBackToTab(npTabId));
npEl.querySelector('.np-title').addEventListener('click', () => npTabId && breeze.mediaBackToTab(npTabId));

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

// ---------------------------------------------------------------------------
// Split screen divider
// ---------------------------------------------------------------------------

const splitDivider = $('#split-divider');
let splitDragging = false;

breeze.onSplitDivider((d) => {
  if (!d || splitDragging) {
    if (!d) splitDivider.classList.remove('show');
    return;
  }
  splitDivider.classList.add('show');
  splitDivider.style.left = `${d.x}px`;
  splitDivider.style.top = `${d.y}px`;
  splitDivider.style.height = `${d.h}px`;
  splitDivider.style.width = `${d.w}px`;
});
breeze.onSplit((on) => {
  document.body.classList.toggle('split-active', on);
  if (!on) splitDivider.classList.remove('show');
});

splitDivider.addEventListener('mousedown', (e) => {
  e.preventDefault();
  splitDragging = true;
  document.body.classList.add('split-dragging');
});
window.addEventListener('mousemove', (e) => {
  if (!splitDragging) return;
  // ratio of the page area; account for sidebar width + pad on the left
  const sb = document.body.classList.contains('sidebar-hidden')
    ? 0
    : parseInt(getComputedStyle(document.documentElement).getPropertyValue('--sidebar-w')) || 280;
  const pageLeft = sb + 10;
  const pageRight = document.body.classList.contains('assistant-open') ? 360 : 14;
  const pageW = window.innerWidth - pageLeft - pageRight;
  const ratio = (e.clientX - pageLeft) / pageW;
  splitDivider.style.left = `${e.clientX}px`;
  breeze.setSplitRatio(ratio);
});
window.addEventListener('mouseup', () => {
  if (!splitDragging) return;
  splitDragging = false;
  document.body.classList.remove('split-dragging');
});

// ---------------------------------------------------------------------------
// Per-pane URL bars (split view) — each drives its own tab independently.
// ---------------------------------------------------------------------------
const splitBarL = $('#split-bar-left');
const splitBarR = $('#split-bar-right');
let splitBarGeom = null; // last geometry from main: { barH, stripY, left, right }

function placeSplitBar(barEl, rect, stripY, barH) {
  barEl.hidden = false;
  barEl.style.left = `${rect.x}px`;
  barEl.style.top = `${stripY}px`;
  barEl.style.width = `${rect.w}px`;
  barEl.style.height = `${barH}px`;
  barEl.dataset.tabId = rect.tabId;
  // shorten the hint on narrow panes instead of clipping it
  barEl.querySelector('.sb-input').placeholder = rect.w < 280 ? 'Search' : 'Search or enter URL';
}

function fillSplitBar(barEl) {
  const id = Number(barEl.dataset.tabId);
  const tab = (state.tabs || []).find((t) => t.id === id);
  const input = barEl.querySelector('.sb-input');
  if (tab && document.activeElement !== input) input.value = collapseUrl(tab.url);
  barEl.querySelector('[data-act="back"]').disabled = !tab?.canGoBack;
  barEl.querySelector('[data-act="forward"]').disabled = !tab?.canGoForward;
}

breeze.onSplitBars((d) => {
  splitBarGeom = d;
  if (!d) {
    splitBarL.hidden = true;
    splitBarR.hidden = true;
    return;
  }
  placeSplitBar(splitBarL, d.left, d.stripY, d.barH);
  placeSplitBar(splitBarR, d.right, d.stripY, d.barH);
  fillSplitBar(splitBarL);
  fillSplitBar(splitBarR);
});

[splitBarL, splitBarR].forEach((barEl) => {
  const input = barEl.querySelector('.sb-input');
  barEl.querySelectorAll('.sb-nav').forEach((btn) =>
    btn.addEventListener('click', () => {
      const id = Number(barEl.dataset.tabId);
      if (id) breeze.tabNav(id, btn.dataset.act);
    })
  );
  input.addEventListener('focus', () => {
    const id = Number(barEl.dataset.tabId);
    const tab = (state.tabs || []).find((t) => t.id === id);
    if (tab) input.value = tab.url; // reveal the full URL while editing
    input.select();
  });
  input.addEventListener('blur', () => fillSplitBar(barEl));
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && input.value.trim()) {
      const id = Number(barEl.dataset.tabId);
      if (id) breeze.tabNavigate(id, input.value.trim());
      input.blur();
    } else if (e.key === 'Escape') {
      input.blur();
    }
  });
});

// Download + update toasts now live in the notification overlay (main process),
// so they always render above the web view regardless of sidebar state.

// Active (not-yet-fired) reminders, listed at the bottom of the sidebar. Shown
// only when there are any; cancelling one removes it everywhere.
const remindersStrip = $('#reminders-strip');
function relTime(ts) {
  const mins = Math.round((ts - Date.now()) / 60000);
  if (mins < 1) return 'in <1 min';
  if (mins < 60) return `in ${mins} min`;
  const h = Math.round(mins / 60);
  if (h < 24) return `in ${h} hr`;
  const d = Math.round(h / 24);
  return `in ${d} day${d > 1 ? 's' : ''}`;
}
function renderReminders(list) {
  remindersStrip.textContent = '';
  const items = (list || []).slice().sort((a, b) => a.fireAt - b.fireAt);
  remindersStrip.classList.toggle('show', items.length > 0);
  for (const r of items) {
    const row = document.createElement('div');
    row.className = 'reminder-item';
    const txt = document.createElement('div');
    txt.className = 'ri-text';
    const label = document.createElement('div');
    label.className = 'ri-label';
    label.textContent = r.label;
    const when = document.createElement('div');
    when.className = 'ri-when';
    when.textContent = relTime(r.fireAt);
    txt.append(label, when);
    const x = document.createElement('button');
    x.className = 'ri-x';
    x.title = 'Cancel reminder';
    x.innerHTML = '<svg viewBox="0 0 16 16"><path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>';
    x.addEventListener('click', () => breeze.confirmDeleteReminder(r.id));
    row.append(txt, x);
    remindersStrip.appendChild(row);
  }
}
breeze.getReminders().then(renderReminders).catch(() => {});
breeze.onReminders(renderReminders);
