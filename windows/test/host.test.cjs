'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { EventEmitter } = require('node:events');
const core = require('../lib/core.cjs');

// Run the real host in a fresh realm with fake Electron, storage, Cloud and clocks.
// The harness never loads Electron, reads generated credentials, opens a window,
// contacts a service, or writes a user profile. It tests the host wiring rather
// than reimplementing the functions under test.
const HOST = path.resolve(__dirname, '../main.cjs');
const NOW = Date.parse('2026-10-04T12:00:00Z');
const copy = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function harness(initial = {}) {
  const data = { settings: { ...core.DEFAULTS, hasOnboarded: true, ...initial.settings } };
  for (const key of ['pins', 'groups', 'history', 'bookmarks', 'chats', 'reminders', 'downloads', 'openTabs']) data[key] = copy(initial[key] || []);
  const listeners = new Set(), writes = [], events = [], timers = new Map(), notifications = [], pendingReplies = [];
  let nextId = 0, cloudOptions, window, applyingChanges = false, syncCalls = 0;
  const store = {
    get: (key, fallback) => copy(Object.hasOwn(data, key) ? data[key] : fallback),
    set(key, value) { data[key] = copy(value); writes.push({ key, value: copy(value) }); for (const fn of listeners) fn(key); },
    subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    updateSettings(patch) { this.set('settings', { ...data.settings, ...core.sanitizeSettings(patch) }); return this.get('settings'); }
  };
  class ClockDate extends Date {
    constructor(...args) { super(...(args.length ? args : [NOW])); }
    static now() { return NOW; }
  }
  function setTimer(fn, delay) { const timer = { id: ++nextId, fn, delay, unref() {} }; timers.set(timer, timer); return timer; }
  function clearTimer(timer) { timers.delete(timer); }
  class Contents extends EventEmitter {
    constructor() {
      super(); this.id = ++nextId; this.url = ''; this.mainFrame = { url: '' }; this.destroyed = false; this.zoom = 1;
      this.navigationHistory = { canGoBack: () => false, canGoForward: () => false, goBack() {}, goForward() {} };
    }
    setWindowOpenHandler(fn) { this.windowOpenHandler = fn; }
    getUserAgent() { return 'Fake Chromium Electron/44.5.1 Breeze/1.0.0'; }
    setUserAgent(value) { this.userAgent = value; }
    getURL() { return this.url; }
    loadURL(url) { this.url = url; this.mainFrame.url = url; return Promise.resolve(); }
    isDestroyed() { return this.destroyed; }
    isLoading() { return false; }
    isCurrentlyAudible() { return false; }
    send(channel, payload) { events.push({ channel, payload: copy(payload) }); }
    focus() {}
    stop() {}
    close() { this.destroyed = true; this.emit('destroyed'); }
    setZoomFactor(value) { this.zoom = value; }
    getZoomFactor() { return this.zoom; }
    setAudioMuted(value) { this.muted = value; }
    insertCSS() { return Promise.resolve('fake-css'); }
    removeInsertedCSS() { return Promise.resolve(); }
    executeJavaScriptInIsolatedWorld() { return this.readDeferred?.promise || Promise.resolve({ title: 'Fixture page', url: this.url, text: 'Visible page evidence', links: [] }); }
    executeJavaScript() { return Promise.resolve('Mentioned page evidence'); }
  }
  class View {
    constructor(options) { this.options = options; this.webContents = new Contents(); }
    setVisible(value) { this.visible = value; }
    setBounds(value) { this.bounds = copy(value); }
  }
  class Window extends EventEmitter {
    constructor(options) {
      super(); window = this; this.options = options; this.webContents = new Contents(); this.children = [];
      this.contentView = { addChildView: view => this.children.push(view), removeChildView: view => { this.children = this.children.filter(item => item !== view); } };
    }
    setMenu() {}
    setBackgroundColor() {}
    isDestroyed() { return false; }
    isMaximized() { return false; }
    getContentBounds() { return { x: 0, y: 0, width: 1400, height: 900 }; }
    loadURL(url) { return this.webContents.loadURL(url); }
    show() {}
  }
  const app = Object.assign(new EventEmitter(), {
    isPackaged: false, getVersion: () => '1.0.0', getPath: () => '/fake-profile',
    requestSingleInstanceLock: () => true, whenReady: () => new Promise(() => {}),
    setName() {}, setAppUserModelId() {}, setPath() {}, quit() {}
  });
  const browserSession = Object.assign(new EventEmitter(), {
    webRequest: { onBeforeRequest() {} }, setPermissionCheckHandler() {}, setPermissionRequestHandler() {}
  });
  const ipc = new Map();
  const electron = {
    app, BrowserWindow: Window, WebContentsView: View,
    ipcMain: { handle: (channel, fn) => ipc.set(channel, fn) },
    session: { fromPartition: () => browserSession },
    nativeTheme: Object.assign(new EventEmitter(), { shouldUseDarkColors: false }),
    safeStorage: {}, net: { fetch() { throw new Error('A host test attempted a live network call.'); } },
    dialog: { showMessageBox: async () => ({ response: 1 }) }, shell: {}, Menu: {},
    Notification: class {
      static isSupported() { return true; }
      constructor(value) { this.value = value; }
      show() { notifications.push(copy(this.value)); }
    }
  };
  const cloud = {
    ready: Promise.resolve(),
    account: {
      state: () => ({ configured: true, signedIn: false }),
      isApplyingChanges: () => applyingChanges,
      syncNow: async () => { syncCalls++; },
      finishAuthCallback: async () => {}
    },
    aero: {
      cancel() {},
      send(input) { const reply = deferred(); pendingReplies.push({ input: copy(input), ...reply }); return reply.promise; }
    }
  };
  const safeFS = { readFileSync() { throw Object.assign(new Error('No generated configuration in host tests.'), { code: 'ENOENT' }); } };
  const modules = {
    electron, 'node:fs': safeFS, 'node:path': path, 'node:url': require('node:url'),
    './lib/core.cjs': { ...core, Store: class { constructor() { return store; } }, id: () => `host-id-${++nextId}` },
    './lib/vault.cjs': { createVault: () => ({ ready: Promise.resolve(), listPasswords: async () => [] }) },
    './lib/cloud.cjs': { createCloud: options => { cloudOptions = options; return cloud; } },
    './lib/adblock.cjs': { createBlocker: () => ({ shouldBlock: () => false, cosmeticCSS: () => '' }) }
  };
  const realm = vm.createContext({
    require(name) { if (!Object.hasOwn(modules, name)) throw new Error(`Unmocked host dependency: ${name}`); return modules[name]; },
    __dirname: path.dirname(HOST), process: { argv: [], env: {}, platform: 'win32', versions: { chrome: 'fake', electron: '44.5.1' } },
    console, URL, Buffer, Date: ClockDate, setTimeout: setTimer, clearTimeout: clearTimer
  });
  vm.runInContext(fs.readFileSync(HOST, 'utf8') + '\n;globalThis.__hostTest = { start, sendAssistant, saveTabs, getTab, snapshot, reminderTimers };', realm, { filename: HOST });
  const host = realm.__hostTest;
  await host.start();
  await Promise.resolve();
  const invoke = (action, payload = {}) => ipc.get('breeze:invoke')({ sender: window.webContents, senderFrame: window.webContents.mainFrame }, action, payload);
  return {
    host, invoke, data, writes, events, timers, notifications, pendingReplies, app, window,
    tools: cloudOptions.tools,
    async importRows(collection, rows) {
      applyingChanges = true;
      try { store.set(collection === 'tabs' ? 'openTabs' : collection, rows); await cloudOptions.onChange(collection, rows); }
      finally { applyingChanges = false; }
    },
    clearTimers() { timers.clear(); },
    get syncCalls() { return syncCalls; }
  };
}

test('host SEARCH works when the Cloud action dispatcher invokes it unbound', async () => {
  const h = await harness();
  const search = h.tools.search;
  const page = await search('near me coffee');
  assert.equal(page.url, core.searchURL('near me coffee'));
  assert.equal(page.text, 'Visible page evidence');
});

test('ask-to-restore tabs survive placeholder creation and quitting without a decision', async () => {
  const saved = { id: 'saved-tab', url: 'https://example.test/saved', title: 'Saved', pinned: true };
  const h = await harness({ openTabs: [saved] });
  assert.deepEqual(h.data.openTabs, [saved]);
  assert.equal(h.host.snapshot().restoreTabs.length, 1);
  h.app.emit('before-quit');
  assert.deepEqual(h.data.openTabs, [saved]);
});

test('an explicit restore dismissal is persisted immediately', async () => {
  const h = await harness({ openTabs: [{ id: 'saved-tab', url: 'https://example.test/saved' }] });
  await h.invoke('browser:restore', { restore: false });
  assert.equal(h.host.snapshot().restoreTabs.length, 0);
  assert.deepEqual(h.data.openTabs, []);
});

function loadWebPage(h, tabId, { title = 'Fixture website', back = false, forward = false } = {}) {
  const wc = h.host.getTab(tabId).view.webContents;
  wc.navigationHistory.canGoBack = () => back;
  wc.navigationHistory.canGoForward = () => forward;
  wc.emit('did-navigate', {}, wc.getURL());
  wc.emit('page-title-updated', {}, title);
  wc.emit('did-stop-loading');
  return wc;
}

test('internal pages offer Back to the first website and preserve it across quitting', async () => {
  const h = await harness();
  const tab = await h.invoke('tab:new', { url: 'https://example.test/first', pinned: true, groupId: 'group-one' });
  const wc = loadWebPage(h, tab.id, { title: 'First website' });
  await h.invoke('browser:internal', { page: 'settings' });
  const internal = h.host.getTab(tab.id);
  assert.equal(internal.page, 'settings');
  assert.equal(internal.title, 'Settings');
  assert.equal(internal.canGoBack, true, 'The renderer must enable Back even without Chromium history');
  assert.equal(internal.canGoForward, false);
  assert.equal(internal.view.webContents, wc, 'The original page remains available without reloading');
  h.app.emit('before-quit');
  assert.deepEqual(h.data.openTabs, [{ id: tab.id, url: tab.url, title: 'First website', groupId: 'group-one', pinned: true, sleeping: false }]);
  const restarted = await harness({ settings: { restoreTabs: 'always' }, openTabs: h.data.openTabs });
  assert.equal(restarted.host.getTab().url, tab.url);
  assert.equal(restarted.host.getTab().pinned, true);
  assert.equal(restarted.host.getTab().groupId, 'group-one');
  await h.invoke('tab:back');
  assert.equal(internal.page, null);
  assert.equal(internal.url, tab.url);
  assert.equal(internal.title, 'First website');
  assert.equal(internal.canGoBack, false);
  assert.equal(internal.canGoForward, false);
});

test('dismissing repeated internal pages restores website metadata and real history controls', async () => {
  const h = await harness();
  const tab = await h.invoke('tab:new', { url: 'https://example.test/current' });
  const wc = loadWebPage(h, tab.id, { title: 'Current website', back: true, forward: true });
  wc.emit('page-favicon-updated', {}, ['https://example.test/favicon.ico']);
  await h.invoke('browser:internal', { page: 'history' });
  await h.invoke('tab:navigate', { url: 'breeze://bookmarks' });
  assert.equal(h.host.getTab(tab.id).canGoForward, false);
  let forwardCalls = 0;
  wc.navigationHistory.goForward = () => { forwardCalls++; };
  await h.invoke('tab:forward');
  assert.equal(forwardCalls, 0, 'Forward must not change the hidden website');
  await h.invoke('browser:internal', { page: null });
  const restored = h.host.getTab(tab.id);
  assert.equal(restored.page, null);
  assert.equal(restored.url, tab.url);
  assert.equal(restored.title, 'Current website');
  assert.equal(restored.favicon, 'https://example.test/favicon.ico');
  assert.equal(restored.canGoBack, true);
  assert.equal(restored.canGoForward, true);
});

test('late hidden website events cannot replace the internal page or disable its Back button', async () => {
  const h = await harness();
  const tab = await h.invoke('tab:new', { url: 'https://example.test/loading' });
  const wc = loadWebPage(h, tab.id, { title: 'Loading website' });
  await h.invoke('browser:internal', { page: 'downloads' });
  wc.url = 'https://example.test/redirected';
  wc.emit('did-start-loading');
  wc.emit('did-navigate', {}, wc.url);
  wc.emit('page-title-updated', {}, 'Redirected website');
  wc.url += '#section';
  wc.emit('did-navigate-in-page', {}, wc.url, true);
  wc.emit('did-fail-load', {}, -105, 'NAME_NOT_RESOLVED', wc.url, true);
  wc.emit('did-stop-loading');
  const internal = h.host.getTab(tab.id);
  assert.equal(internal.page, 'downloads');
  assert.equal(internal.url, 'breeze://downloads');
  assert.equal(internal.title, 'Downloads');
  assert.equal(internal.loading, false);
  assert.equal(internal.error, null);
  assert.equal(internal.canGoBack, true);
  assert.equal(h.data.openTabs[0].url, wc.url);
  assert.equal(h.data.openTabs[0].title, 'Redirected website');
  await h.invoke('tab:back');
  assert.equal(internal.url, wc.url);
  assert.equal(internal.title, 'Redirected website');
  assert.equal(internal.canGoBack, false);
  assert.match(internal.error, /NAME_NOT_RESOLVED/);
});

test('internal pages retain a sleeping website and can return after its view is retired', async () => {
  const h = await harness();
  const tab = await h.invoke('tab:new', { url: 'https://example.test/sleeping' });
  loadWebPage(h, tab.id, { title: 'Sleeping website' });
  await h.invoke('browser:internal', { page: 'settings' });
  await h.invoke('tab:new');
  assert.equal(await h.invoke('tab:sleep', { id: tab.id }), true);
  await h.invoke('tab:activate', { id: tab.id });
  assert.equal(h.host.getTab(tab.id).view, undefined);
  await h.invoke('tab:back');
  const restored = h.host.getTab(tab.id);
  assert.equal(restored.page, null);
  assert.equal(restored.url, tab.url);
  assert.equal(restored.title, 'Sleeping website');
  assert.equal(restored.sleeping, false);
  assert.equal(restored.view.webContents.getURL(), tab.url);
  assert.equal(h.data.openTabs[0].url, tab.url);
});

test('a new web navigation replaces the retained website and internal-only tabs stay internal', async () => {
  const h = await harness();
  await h.invoke('browser:internal', { page: 'history' });
  await h.invoke('tab:back');
  await h.invoke('browser:internal', { page: null });
  assert.equal(h.host.getTab().page, 'history');
  assert.equal(h.host.getTab().canGoBack, false);
  assert.deepEqual(h.data.openTabs, []);
  await h.invoke('tab:navigate', { url: 'https://example.test/old' });
  loadWebPage(h, h.host.getTab().id, { title: 'Old website' });
  await h.invoke('browser:internal', { page: 'settings' });
  await h.invoke('tab:navigate', { url: 'https://example.test/new' });
  loadWebPage(h, h.host.getTab().id, { title: 'New website' });
  await h.invoke('browser:internal', { page: 'history' });
  await h.invoke('tab:back');
  assert.equal(h.host.getTab().url, 'https://example.test/new');
  assert.equal(h.host.getTab().title, 'New website');
  assert.equal(h.data.openTabs.length, 1);
  assert.equal(h.data.openTabs[0].url, 'https://example.test/new');
});

test('explicitly waking a covered sleeping tab loads its website while keeping the internal page', async () => {
  const h = await harness();
  const tab = await h.invoke('tab:new', { url: 'https://example.test/sleeping' });
  loadWebPage(h, tab.id, { title: 'Sleeping website' });
  await h.invoke('tab:new');
  await h.invoke('tab:sleep', { id: tab.id });
  await h.invoke('tab:navigate', { id: tab.id, url: 'breeze://settings' });
  await h.invoke('tab:sleep', { id: tab.id, sleeping: false });
  const covered = h.host.getTab(tab.id);
  assert.equal(covered.view.webContents.getURL(), tab.url);
  assert.equal(covered.page, 'settings');
  assert.equal(covered.canGoBack, true);
  assert.equal(h.data.openTabs.find(row => row.id === tab.id).url, tab.url);
  await h.invoke('tab:activate', { id: tab.id });
  await h.invoke('tab:back');
  assert.equal(covered.page, null);
  assert.equal(covered.url, tab.url);
  assert.equal(covered.title, 'Sleeping website');
});

test('canceled old reply cannot clear a newer run or add its answer to the new chat', async () => {
  const h = await harness();
  const first = h.host.sendAssistant({ text: 'Old question' });
  assert.equal(h.pendingReplies.length, 1);
  await h.invoke('assistant:new');
  const newChatId = h.host.snapshot().assistant.chatId;
  const second = h.host.sendAssistant({ text: 'New question' });
  assert.equal(h.pendingReplies.length, 2);
  // A provider may resolve after cancellation; host generation checks still apply.
  h.pendingReplies[0].resolve({ answer: 'Stale answer' });
  await first;
  assert.equal(h.host.snapshot().assistant.running, true);
  assert.equal(h.host.snapshot().assistant.error, null);
  assert.deepEqual(copy(h.host.snapshot().assistant.messages).map(item => item.text), ['New question']);
  h.pendingReplies[1].resolve({ answer: 'Current answer' });
  await second;
  assert.equal(h.host.snapshot().assistant.running, false);
  assert.equal(h.data.chats.length, 1);
  assert.equal(h.data.chats[0].id, newChatId);
  assert.deepEqual(h.data.chats[0].messages.map(item => item.text), ['New question', 'Current answer']);
});

test('stop followed by a new send ignores a late error from the stopped request', async () => {
  const h = await harness();
  const first = h.host.sendAssistant({ text: 'Old question' });
  await h.invoke('assistant:stop');
  const second = h.host.sendAssistant({ text: 'New question' });
  h.pendingReplies[0].reject(new Error('Late provider error'));
  await first;
  assert.equal(h.host.snapshot().assistant.running, true);
  assert.equal(h.host.snapshot().assistant.error, null);
  h.pendingReplies[1].resolve({ answer: 'Current answer' });
  await second;
});

test('cancellation during page collection cannot start a stale Cloud request', async () => {
  const h = await harness();
  const page = await h.invoke('tab:new', { url: 'https://example.test/slow-page' });
  const read = deferred();
  h.host.getTab(page.id).view.webContents.readDeferred = read;
  const oldRun = h.host.sendAssistant({ text: 'Old question' });
  await h.invoke('assistant:new');
  await h.invoke('tab:new', { url: 'breeze://newtab' });
  const newRun = h.host.sendAssistant({ text: 'New question' });
  assert.equal(h.pendingReplies.length, 1);
  read.resolve({ title: 'Late page', url: page.url, text: 'Old evidence', links: [] });
  await oldRun;
  assert.equal(h.pendingReplies.length, 1, 'The canceled read must not dispatch an old turn after a new one');
  assert.equal(h.host.snapshot().assistant.running, true);
  h.pendingReplies[0].resolve({ answer: 'New answer' });
  await newRun;
});

test('current web page is marked isCurrent while mentioned tabs remain reference context', async () => {
  const h = await harness();
  const mentioned = await h.invoke('tab:new', { url: 'https://example.test/reference' });
  const current = await h.invoke('tab:new', { url: 'https://example.test/current' });
  const run = h.host.sendAssistant({ text: 'Explain this page', tabIds: [mentioned.id] });
  for (let turn = 0; turn < 8 && !h.pendingReplies.length; turn++) await Promise.resolve();
  const input = h.pendingReplies[0]?.input;
  assert.ok(input, 'Host should hand collected page context to Aero');
  assert.equal(input.contexts[0].isCurrent, true);
  assert.equal(input.contexts[0].url, current.url);
  assert.equal(input.contexts[1].isCurrent, undefined);
  assert.equal(input.contexts[1].url, mentioned.url);
  h.pendingReplies[0].resolve({ answer: 'Summary' });
  await run;
});

test('activating the secondary split swaps panes and keeps two distinct visible views', async () => {
  const h = await harness();
  const first = await h.invoke('tab:new', { url: 'https://example.test/first' });
  const second = await h.invoke('tab:new', { url: 'https://example.test/second', split: true });
  await h.invoke('browser:layout', { x: 250, y: 60, width: 500, height: 700, split: { x: 750, y: 60, width: 500, height: 700 } });
  await h.invoke('tab:activate', { id: second.id });
  const state = h.host.snapshot();
  assert.equal(state.activeTabId, second.id);
  assert.equal(state.splitTabId, first.id);
  assert.equal(h.host.getTab(second.id).view.bounds.x, 250);
  assert.equal(h.host.getTab(first.id).view.bounds.x, 750);
  assert.equal(h.host.getTab(first.id).view.visible, true);
  assert.equal(h.host.getTab(second.id).view.visible, true);
});

test('new tabs opened from a pinned site retain the pinned flag in memory and storage', async () => {
  const h = await harness();
  const tab = await h.invoke('tab:new', { url: 'https://example.test/pinned', pinned: true });
  assert.equal(tab.pinned, true);
  assert.equal(h.host.getTab(tab.id).pinned, true);
  assert.equal(h.data.openTabs.find(item => item.id === tab.id).pinned, true);
});

test('imported reminders replace old timers and fire without restarting Breeze', async () => {
  const h = await harness();
  await h.invoke('reminder:add', { text: 'Old reminder', minutes: 5 });
  const oldTimer = [...h.host.reminderTimers.values()][0];
  const reminder = { id: 'cloud-reminder', text: 'Imported reminder', dueAt: new Date(NOW + 60000).toISOString(), fired: false };
  await h.importRows('reminders', [reminder]);
  assert.equal(h.host.reminderTimers.size, 1);
  assert.equal(h.timers.has(oldTimer), false);
  const timer = h.host.reminderTimers.get(reminder.id);
  assert.ok(timer, 'A cloud import must install a reminder timer');
  assert.equal(timer.delay, 60000);
  timer.fn();
  assert.equal(h.data.reminders[0].fired, true);
  assert.deepEqual(h.notifications, [{ title: 'Breeze reminder', body: reminder.text }]);
  await h.importRows('reminders', []);
  assert.equal(h.host.reminderTimers.size, 0);
});

test('applying Cloud rows does not schedule an endless follow-up sync', async () => {
  const h = await harness();
  h.clearTimers();
  await h.importRows('bookmarks', [{ id: 'cloud-bookmark', url: 'https://example.test/synced' }]);
  assert.equal(h.timers.size, 0);
  assert.equal(h.syncCalls, 0);
});

test('Ctrl+D on an internal page produces a friendly message rather than throwing', async () => {
  const h = await harness();
  let prevented = false;
  assert.doesNotThrow(() => h.window.webContents.emit('before-input-event', { preventDefault() { prevented = true; } }, { type: 'keyDown', key: 'd', control: true }));
  assert.equal(prevented, true);
  assert.ok(h.events.some(item => item.channel === 'breeze:event' && item.payload.type === 'toast' && /website/i.test(item.payload.text)));
});


test('switching to a saved chat invalidates the active reply', async () => {
  const saved={id:'saved-chat',title:'Saved',messages:[{role:'user',text:'Existing question'},{role:'ai',text:'Existing answer'}]};
  const h=await harness({chats:[saved]});
  const pending=h.host.sendAssistant({text:'Old active question'});
  await h.invoke('assistant:open',{id:'saved-chat'});
  h.pendingReplies[0].resolve({answer:'Stale answer'});
  await pending;
  assert.equal(h.host.snapshot().assistant.chatId,'saved-chat');
  assert.deepEqual(copy(h.host.snapshot().assistant.messages),saved.messages);
  assert.deepEqual(h.data.chats,[saved]);
});

test('website popups get a sandboxed tab without a privileged preload', async () => {
  const h=await harness();
  const parent=await h.invoke('tab:new',{url:'https://example.test/parent'});
  const handler=h.host.getTab(parent.id).view.webContents.windowOpenHandler;
  assert.equal(handler({url:'file:///private',disposition:'new-window'}).action,'deny');
  const response=handler({url:'https://example.test/popup',disposition:'foreground-tab'});
  assert.equal(response.action,'allow');
  const wc=response.createWindow({webPreferences:{nodeIntegration:true,preload:'/untrusted-preload'}});
  const popup=h.host.getTab(h.host.snapshot().activeTabId);
  assert.equal(popup.view.webContents,wc);
  assert.equal(popup.view.options.webPreferences.preload,undefined);
  assert.equal(popup.view.options.webPreferences.nodeIntegration,false);
  assert.equal(popup.view.options.webPreferences.contextIsolation,true);
  assert.equal(popup.view.options.webPreferences.sandbox,true);
});
