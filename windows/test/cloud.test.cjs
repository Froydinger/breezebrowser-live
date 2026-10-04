'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createCloud, parseAction, parseTask, plainQuery, isAuthCallback, mergePayload, publicSupabaseKey } = require('../lib/cloud.cjs');
// Dedicated fake OS crypto: only tests use this reversible codec.
const safeStorage = { isEncryptionAvailable: () => true, encryptString: text => Buffer.from(text).map(byte => byte ^ 91), decryptString: bytes => Buffer.from(bytes).map(byte => byte ^ 91).toString() };
function memory(initial = {}) { const data = structuredClone(initial); return { data, get: (key, fallback) => structuredClone(data[key] ?? fallback), set: (key, value) => { data[key] = structuredClone(value); } }; }
function response(value, status = 200) { return { ok: status >= 200 && status < 300, status, text: async () => value === undefined ? '' : JSON.stringify(value) }; }
const config = { aiBaseURL: 'https://ai.example.test', aiClientToken: 'test-build-token', supabaseURL: 'https://account.example.test', supabaseAnonKey: 'sb_publishable_test' };
function harness({ replies = ['Hello.'], handler, initial = {}, tools = {}, override = {} } = {}) {
  const calls = [], events = [], changes = [], store = memory(initial); let id = 0;
  const cloud = createCloud({ config, store, safeStorage, now: () => 1800000000000, uuid: () => `test-id-${++id}`, tools, onEvent: event => events.push(event), onChange: (collection, rows) => changes.push({ collection, rows }), fetch: async (url, options) => {
    const call = { url, options, body: options.body ? JSON.parse(options.body) : undefined }; calls.push(call);
    if (handler) return handler(call, calls);
    const reply = replies.shift(); return typeof reply === 'object' ? response(reply.body, reply.status) : response({ choices: [{ message: { content: reply } }] });
  }, ...override });
  return { cloud, calls, events, changes, store };
}
function session() { return { access_token: 'user-access-secret', refresh_token: 'user-refresh-secret', expires_in: 3600, user: { id: 'user-id', email: 'owner@example.test' } }; }
function accountServer({ prefs = {}, collections = {}, token = session(), signup = token } = {}) {
  let savedPrefs = { bookmarks: false, tabs: false, history: false, chats: false, reminders: false, ...prefs };
  return call => {
    const u = new URL(call.url);
    if (u.pathname === '/auth/v1/token') return response(token);
    if (u.pathname === '/auth/v1/signup') return response(signup);
    if (u.pathname === '/auth/v1/logout') return response(undefined, 204);
    if (u.pathname.endsWith('/breeze_sync_preferences')) {
      if (call.options.method === 'GET') return response([savedPrefs]);
      savedPrefs = { ...call.body }; return response(undefined, 204);
    }
    if (u.pathname.endsWith('/breeze_sync_collections')) {
      if (call.options.method === 'GET') { const name = u.searchParams.get('collection').replace('eq.', ''); return response(collections[name] ? [{ payload: collections[name] }] : []); }
      collections[call.body.collection] = call.body.payload; return response(undefined, 204);
    }
    throw new Error(`Unexpected fake route ${u.pathname}`);
  };
}

test('Aero uses app bearer, stable install id, one request id per action loop, no model/BYOK', async () => {
  const h = harness({ replies: ['READ', 'Here is the page summary.'], tools: { read: async () => ({ text: 'Page evidence', title: 'Example', url: 'https://example.com' }) } });
  const result = await h.cloud.aero.send({ text: 'What is on this page?' });
  assert.equal(result.answer, 'Here is the page summary.'); assert.equal(h.calls.length, 2);
  for (const call of h.calls) { assert.equal(call.url, 'https://ai.example.test/v1/chat/completions'); assert.equal(call.options.headers.Authorization, 'Bearer test-build-token'); assert.equal(call.body.model, undefined); assert.equal(call.options.redirect, 'error'); }
  assert.equal(h.calls[0].options.headers['X-Breeze-Request-Id'], h.calls[1].options.headers['X-Breeze-Request-Id']);
  assert.equal(h.calls[0].options.headers['X-Breeze-Client-Id'], h.store.data.settings.aiCloudClientId);
  assert.ok(h.events.some(event => event.type === 'complete')); assert.equal(JSON.stringify(h.events).includes('test-build-token'), false);
});
test('unconfigured and insecure HTTP builds do not make AI requests', async () => {
  for (const c of [{}, { ...config, aiBaseURL: 'http://example.test' }, { ...config, aiClientToken: '' }]) {
    const h = harness({ override: { config: c } }); await assert.rejects(h.cloud.aero.send('hello'), /not configured/); assert.equal(h.calls.length, 0);
  }
});
test('first-call authentication and quota errors surface accurately', async () => {
  for (const [status, message] of [[401, /rejected this app build/], [429, /Daily AI limit reached/]]) {
    const h = harness({ replies: [{ status, body: { error: status === 429 ? 'Daily AI limit reached.' : 'unauthorized' } }] });
    await assert.rejects(h.cloud.aero.send('hello'), message); assert.equal(h.calls.length, 1); assert.ok(h.events.some(event => event.type === 'error'));
  }
});
test('400 retries minimal body with same turn identity', async () => {
  const h = harness({ replies: [{ status: 400, body: { error: 'unsupported reasoning option' } }, 'Done with the answer.'] });
  await h.cloud.aero.send('hello'); assert.equal(h.calls[0].body.reasoning_effort, 'low'); assert.equal(h.calls[1].body.reasoning_effort, undefined);
  assert.equal(h.calls[0].options.headers['X-Breeze-Request-Id'], h.calls[1].options.headers['X-Breeze-Request-Id']);
});
test('context overflow retries fresh context with current evidence', async () => {
  const h = harness({ replies: [{ status: 400, body: { error: { message: 'maximum context length exceeded' } } }, 'Fresh answer.'] });
  const result = await h.cloud.aero.send({ text: 'Summarize it', history: [{ role: 'user', text: 'old-history-marker' }], contexts: [{ isCurrent: true, label: 'Current', text: 'current-evidence-marker' }] });
  assert.equal(result.answer, 'Fresh answer.'); assert.equal(h.calls[1].body.messages.length, 2);
  assert.ok(!JSON.stringify(h.calls[1].body).includes('old-history-marker')); assert.ok(JSON.stringify(h.calls[1].body).includes('current-evidence-marker'));
});
test('cancel aborts pending fetch and never emits late completion/error', async () => {
  let release, started; const start = new Promise(resolve => { started = resolve; });
  const h = harness({ handler: async call => { started(); await new Promise(resolve => { release = resolve; }); return response({ choices: [{ message: { content: 'late' } }] }); } });
  const pending = h.cloud.aero.send('hello'); await start; h.cloud.aero.cancel(); release();
  await assert.rejects(pending, { name: 'AbortError' }); assert.equal(h.calls[0].options.signal.aborted, true);
  assert.deepEqual(h.events.filter(event => ['complete', 'error', 'cancelled'].includes(event.type)).map(event => event.type), ['cancelled']);
});
test('cancel during a tool prevents another model call', async () => {
  let release, started; const start = new Promise(resolve => { started = resolve; });
  const h = harness({ replies: ['READ'], tools: { read: async () => { started(); await new Promise(resolve => { release = resolve; }); return 'late page'; } } });
  const pending = h.cloud.aero.send('read page'); await start; h.cloud.aero.cancel(); release(); await assert.rejects(pending, { name: 'AbortError' }); assert.equal(h.calls.length, 1);
});
test('8-action cap forces synthesis without a ninth browser operation', async () => {
  let count = 0; const h = harness({ replies: [...Array(9).fill('READ'), 'Synthesized actual findings.'], tools: { read: async () => `Different result ${++count}` } });
  const result = await h.cloud.aero.send('keep reading'); assert.equal(count, 8); assert.equal(result.answer, 'Synthesized actual findings.');
});
test('identical repeated action/result stops through fresh synthesis', async () => {
  let count = 0; const h = harness({ replies: ['READ', 'READ', 'Here are the findings.'], tools: { read: async () => { count++; return 'same'; } } });
  await h.cloud.aero.send('read'); assert.equal(count, 2); assert.equal(h.calls[2].body.messages.length, 2);
});
test('strict action parser does not execute ordinary prose; tasks use unique prefixes', () => {
  assert.equal(parseAction('- Click Settings'), null); assert.equal(parseAction('Open Settings → Privacy'), null);
  assert.deepEqual(parseAction('**SEARCH:** pizza near me'), { type: 'search', target: 'pizza near me' });
  assert.deepEqual(parseAction('Sure — OPEN: example.com'), { type: 'open', target: 'example.com' });
  assert.deepEqual(parseAction('TYPE: [3] | hello world'), { type: 'type', target: '[3]', value: 'hello world' });
  assert.deepEqual(parseAction('REMIND: 10 | Stretch'), { type: 'remind', minutes: 10, text: 'Stretch' });
  assert.equal(parseAction('REMIND: -5 | Nope'), null);
  assert.deepEqual(parseTask('/res electric cars'), { task: 'research', prompt: 'electric cars' }); assert.equal(parseTask('/unknown'), null);
  assert.equal(plainQuery('pizza near me site:example.com OR "food"'), 'pizza near me food');
});
test('private browsing context is never transmitted', async () => {
  const h = harness(); await assert.rejects(h.cloud.aero.send({ text: 'this page', contexts: [{ isCurrent: true, isPrivate: true, text: 'private words' }] }), /private browsing/); assert.equal(h.calls.length, 0);
});
test('image context uses server-supported multimodal messages and never appears in events', async () => {
  const h = harness(); await h.cloud.aero.send({ text: 'read image', images: ['data:image/png;base64,YWJj'] });
  const last = h.calls[0].body.messages.at(-1); assert.equal(last.content[1].image_url.url, 'data:image/png;base64,YWJj'); assert.equal(JSON.stringify(h.events).includes('data:image'), false);
});
test('research opens and reads four source pages before grounded synthesis', async () => {
  const links = Array.from({ length: 4 }, (_, i) => ({ title: `Source ${i}`, url: `https://example${i}.com/article`, snippet: 'Research evidence' }));
  const opened = [];
  const h = harness({ replies: ['QUESTION: What are the facts?\nSEARCH: facts\nSEARCH: evidence', links.map(link => link.url).join('\n'), 'notes0', 'notes1', 'notes2', 'notes3', 'Sourced final answer.'], tools: { search: async () => ({ text: 'Results', links }), open: async url => { opened.push(url); return { title: 'A source', url, text: 'actual source evidence '.repeat(30) }; } } });
  const result = await h.cloud.aero.send('/research the facts'); assert.equal(result.task, 'research'); assert.equal(opened.length, 4); assert.equal(result.sources.length, 4);
  const finalPrompt = h.calls.at(-1).body.messages.at(-1).content; assert.ok(finalPrompt.includes('4 usable sources')); assert.ok(finalPrompt.includes('notes3'));
});
test('summarize and creator tasks use main page text with honest video limits', async () => {
  for (const task of ['summarize', 'youtube']) {
    let main; const h = harness({ replies: ['A useful result.'], tools: { read: async options => { main = options.main; return { title: 'A page', url: 'https://example.com', text: 'actual text '.repeat(80) }; } } });
    const result = await h.cloud.aero.send('/' + task); assert.equal(main, true); assert.equal(result.task, task);
    if (task === 'youtube') assert.match(h.calls[0].body.messages.at(-1).content, /never invent performance metrics/);
  }
});
test('account sign-in uses Supabase contract and keeps tokens/profile off plaintext disk/events', async () => {
  const h = harness({ handler: accountServer() }); await h.cloud.ready; const result = await h.cloud.account.signIn({ email: ' owner@example.test ', password: 'account-password' });
  assert.equal(result.signedIn, true); assert.equal(h.calls[0].url, 'https://account.example.test/auth/v1/token?grant_type=password'); assert.equal(h.calls[0].body.email, 'owner@example.test');
  assert.equal(h.calls[1].options.headers.Authorization, 'Bearer user-access-secret'); assert.equal(h.calls[1].options.headers.apikey, config.supabaseAnonKey);
  const disk = JSON.stringify(h.store.data); for (const secret of ['user-access-secret', 'user-refresh-secret', 'owner@example.test', 'account-password']) assert.ok(!disk.includes(secret));
  assert.ok(!JSON.stringify(h.events).includes('user-access-secret')); assert.ok(!JSON.stringify(h.events).includes('account-password'));
});
test('signup keeps PKCE verifier encrypted and sends challenge in JSON body', async () => {
  const h = harness({ handler: accountServer({ signup: { user: { id: 'pending' } } }) });
  const result = await h.cloud.account.signUp({ email: 'owner@example.test', password: 'new-password' });
  assert.match(result.message, /confirm/); assert.equal(result.signedIn, false);
  const verifier = (await h.cloud.vault.get('cloudSession')).pending_verifier;
  assert.equal(verifier.length, 43); assert.equal(h.calls[0].body.code_challenge_method, 's256'); assert.notEqual(h.calls[0].body.code_challenge, verifier);
  assert.ok(!JSON.stringify(h.store.data).includes(verifier)); assert.ok(!JSON.stringify(h.store.data).includes('new-password'));
});
test('Google PKCE callback accepts strict native callback shapes and rejects lookalikes', async () => {
  const h = harness({ handler: accountServer() }); const auth = new URL(await h.cloud.account.beginGoogleSignIn());
  assert.equal(auth.searchParams.get('provider'), 'google'); assert.equal(auth.searchParams.get('prompt'), 'select_account');
  for (const url of ['https://auth-callback/?code=bad', 'com.froydinger.breeze://auth-callback.evil/?code=bad', 'com.froydinger.breeze://auth-callback/extra?code=bad']) assert.equal(isAuthCallback(url), false);
  assert.equal(isAuthCallback('com.froydinger.breeze:/auth-callback?code=good'), true);
  await assert.rejects(h.cloud.account.finishAuthCallback('https://auth-callback/?code=bad'), /unexpected/); assert.equal(h.calls.length, 0);
  await h.cloud.account.finishAuthCallback('com.froydinger.breeze://auth-callback#code=good');
  assert.equal(h.calls[0].body.auth_code, 'good'); assert.ok(h.calls[0].body.code_verifier); assert.equal((await h.cloud.vault.get('cloudSession')).pending_verifier, undefined);
});
test('unsolicited/implicit-token OAuth callbacks cannot sign the app into another account', async () => {
  const h = harness({ handler: accountServer() });
  await assert.rejects(h.cloud.account.finishAuthCallback('com.froydinger.breeze://auth-callback?code=unsolicited'), /expired/);
  assert.equal(h.calls.length, 0); assert.equal(h.cloud.account.state().signedIn, false);
});
test('sync is opt-in and excludes passwords/private/internal pages', async () => {
  const h = harness({ handler: accountServer({ prefs: { bookmarks: true } }), initial: { bookmarks: [{ id: 'public', url: 'https://example.com', title: 'Public', ts: 1 }, { id: 'private', url: 'https://secret.test', isPrivate: true }, { id: 'internal', url: 'breeze://settings' }], history: [{ id: 'h', url: 'https://history.test' }] } });
  await h.cloud.account.signIn({ email: 'owner@example.test', password: 'test-password' });
  const pushes = h.calls.filter(call => call.body?.collection); assert.equal(pushes.length, 1); assert.equal(pushes[0].body.collection, 'bookmarks');
  assert.deepEqual(pushes[0].body.payload.entries.map(entry => entry.id), ['public']); assert.equal(h.store.data.history.length, 1);
});
test('sync merge keeps newest entries and tombstones; chats merge messages and sources', () => {
  const local = { entries: [{ id: 'one', url: 'https://example.com', title: 'old', time: 1, _updatedAt: 1 }, { id: 'deleted', url: 'https://gone.test' }], deletedIds: [] };
  const remote = { formatVersion: 1, entries: [{ id: 'one', url: 'https://example.com', title: 'new', time: 1, _updatedAt: 2 }], deletedIds: ['deleted'] };
  const result = mergePayload('bookmarks', local, remote); assert.equal(result.entries[0].title, 'new'); assert.equal(result.entries.length, 1); assert.deepEqual(result.deletedIds, ['deleted']);
  const chat = mergePayload('chats', { entries: [{ id: 'c', messages: [{ role: 'user', text: 'Hi' }], _updatedAt: 1 }] }, { entries: [{ id: 'c', messages: [{ role: 'user', text: 'Hi' }, { role: 'ai', text: 'Hello' }], _updatedAt: 2 }] });
  assert.equal(chat.entries[0].messages.length, 2);
  assert.throws(() => mergePayload('bookmarks', local, { formatVersion: 2 }), /newer sync format/);
});
test('deleted local record creates durable tombstone instead of resurrecting from cloud', async () => {
  const remote = {}, h = harness({ handler: accountServer({ prefs: { bookmarks: true }, collections: remote }), initial: { bookmarks: [{ id: 'b', url: 'https://example.com', title: 'Keep', ts: 1 }] } });
  await h.cloud.account.signIn({ email: 'owner@example.test', password: 'test-password' });
  h.store.set('bookmarks', []); await h.cloud.account.syncNow(); assert.deepEqual(remote.bookmarks.entries, []); assert.deepEqual(remote.bookmarks.deletedIds, ['b']);
});
test('tab sync preserves local group/pin metadata without uploading it', async () => {
  const remote = {}, h = harness({ handler: accountServer({ prefs: { tabs: true }, collections: remote }), initial: { openTabs: [{ id: 'tab', url: 'https://example.com', title: 'A', groupId: 'group', pinned: true, sleeping: true }] } });
  await h.cloud.account.signIn({ email: 'owner@example.test', password: 'test-password' });
  assert.equal(h.store.data.openTabs[0].groupId, 'group'); assert.equal(h.store.data.openTabs[0].pinned, true); assert.equal(remote.tabs.entries[0].groupId, undefined);
});
test('sync preference is persisted server-side then performs first sync', async () => {
  const h = harness({ handler: accountServer(), initial: { bookmarks: [{ id: 'b', url: 'https://example.com' }] } });
  await h.cloud.account.signIn({ email: 'owner@example.test', password: 'test-password' }); await h.cloud.account.setSyncPreference('bookmarks', true);
  assert.equal(h.cloud.account.state().preferences.bookmarks, true); assert.ok(h.calls.some(call => call.body?.bookmarks === true)); assert.ok(h.calls.some(call => call.body?.collection === 'bookmarks'));
  await assert.rejects(h.cloud.account.setSyncPreference('passwords', true), /Unknown/);
});
test('signout removes encrypted session and selected synced data but keeps unsynced data', async () => {
  const h = harness({ handler: accountServer({ prefs: { bookmarks: true } }), initial: { bookmarks: [{ id: 'b', url: 'https://example.com' }], history: [{ id: 'h' }] } });
  await h.cloud.account.signIn({ email: 'owner@example.test', password: 'test-password' }); await h.cloud.account.signOut();
  assert.equal(h.cloud.account.state().signedIn, false); assert.equal(await h.cloud.vault.get('cloudSession'), null); assert.deepEqual(h.store.data.bookmarks, []); assert.equal(h.store.data.history.length, 1);
});
test('unavailable OS crypto does not crash startup or disable configured Aero', async () => {
  const h = harness({ override: { safeStorage: { isEncryptionAvailable: () => false } } }); await h.cloud.ready;
  assert.equal(h.cloud.account.state().secureStorageAvailable, false); assert.equal(h.cloud.aero.state().configured, true);
  await assert.rejects(h.cloud.account.signIn({ email: 'a@b.c', password: 'password' }), /secure storage/); assert.equal(h.calls.length, 0);
});
test('secret/service role Supabase keys are rejected as client config', () => {
  assert.equal(publicSupabaseKey('sb_secret_private'), false);
  const jwt = role => `header.${Buffer.from(JSON.stringify({ role })).toString('base64url')}.signature`;
  assert.equal(publicSupabaseKey(jwt('service_role')), false); assert.equal(publicSupabaseKey(jwt('anon')), true); assert.equal(publicSupabaseKey('sb_publishable_public'), true);
});

test('tool methods retain receiver and OPEN bare domains normalize safely', async () => {
  const opened = [], tools = { open: async target => { opened.push(target); return 'evidence'; }, search: async function(query, opts) { return this.open('https://search.test/?q=' + encodeURIComponent(query), opts); } };
  const h = harness({ replies: ['OPEN: example.com', 'SEARCH: pizza near me', 'Found it.'], tools });
  await h.cloud.aero.send('find things'); assert.equal(opened[0], 'https://example.com'); assert.match(opened[1], /pizza%20near%20me/);
});
test('LOOK passes actual screenshot image to model instead of claiming text is visual evidence', async () => {
  const h = harness({ replies: ['LOOK', 'I see the screenshot.'], tools: { look: async () => ({ text: 'Actual screenshot attached.', image: 'data:image/png;base64,c2NyZWVu', url: 'https://example.com' }) } });
  await h.cloud.aero.send('look here'); assert.equal(h.calls[1].body.messages.at(-1).content[1].image_url.url, 'data:image/png;base64,c2NyZWVu');
});
test('Windows ISO/text reminders round-trip into native millisecond/title sync format', async () => {
  const remote = {}, h = harness({ handler: accountServer({ prefs: { reminders: true }, collections: remote }), initial: { reminders: [{ id: 'r', text: 'Stretch', dueAt: '2027-01-15T08:00:00.000Z', fired: false }] } });
  await h.cloud.account.signIn({ email: 'owner@example.test', password: 'test-password' });
  assert.equal(remote.reminders.entries[0].title, 'Stretch'); assert.equal(typeof remote.reminders.entries[0].dueAt, 'number');
  assert.equal(h.store.data.reminders[0].text, 'Stretch'); assert.equal(h.store.data.reminders[0].dueAt, '2027-01-15T08:00:00.000Z'); assert.equal(h.store.data.reminders[0].fired, false);
});
test('remote apply flag suppresses host feedback sync while collections are updated', async () => {
  let h; const flags = [];
  h = harness({ handler: accountServer({ prefs: { bookmarks: true } }), initial: { bookmarks: [{ id: 'b', url: 'https://example.com' }] }, override: { onChange: () => flags.push(h.cloud.account.isApplyingChanges()) } });
  await h.cloud.account.signIn({ email: 'owner@example.test', password: 'test-password' }); assert.deepEqual(flags, [true]); assert.equal(h.cloud.account.isApplyingChanges(), false);
});
test('signout while sync fetch is pending cannot resurrect credentials or data', async () => {
  let delay = false, release, started; const start = new Promise(resolve => { started = resolve; }), server = accountServer({ prefs: { bookmarks: true } });
  const h = harness({ handler: async call => { if (delay && call.url.includes('breeze_sync_collections') && call.options.method === 'GET') { started(); await new Promise(resolve => { release = resolve; }); return response([{ payload: { formatVersion: 1, entries: [{ id: 'late', url: 'https://late.test' }], deletedIds: [] } }]); } return server(call); }, initial: { bookmarks: [{ id: 'b', url: 'https://example.com' }] } });
  await h.cloud.account.signIn({ email: 'owner@example.test', password: 'test-password' });
  delay = true; const pending = h.cloud.account.syncNow(); await start; await h.cloud.account.signOut(); release(); await assert.rejects(pending, { name: 'AbortError' });
  assert.deepEqual(h.store.data.bookmarks, []); assert.equal(h.cloud.account.state().signedIn, false); assert.equal(await h.cloud.vault.get('cloudSession'), null);
});
test('expired saved session refreshes once and keeps refreshed tokens encrypted', async () => {
  const h = harness({ handler: accountServer() }); await h.cloud.account.signIn({ email: 'owner@example.test', password: 'test-password' });
  const saved = await h.cloud.vault.get('cloudSession'); saved.expires_at = 0; await h.cloud.vault.set('cloudSession', saved);
  const calls = [], next = createCloud({ config, store: h.store, safeStorage, fetch: async (url, options) => { calls.push({ url, options }); return url.includes('grant_type=refresh_token') ? response({ ...session(), access_token: 'refreshed-access' }) : response([{ bookmarks: false }]); } });
  await next.ready; await next.account.syncNow(); assert.equal(calls.filter(call => call.url.includes('grant_type=refresh_token')).length, 1); assert.equal(calls[1].options.headers.Authorization, 'Bearer refreshed-access');
  assert.ok(!JSON.stringify(h.store.data).includes('refreshed-access'));
});

test('token-hash confirmation cannot inject a different account into an existing Google flow', async () => {
  const h = harness({ handler: accountServer() }); await h.cloud.account.beginGoogleSignIn();
  await assert.rejects(h.cloud.account.finishAuthCallback('com.froydinger.breeze://auth-callback?token_hash=attacker&type=signup'), /not supported/);
  assert.equal(h.calls.length, 0); assert.equal(h.cloud.account.state().signedIn, false);
});
test('email confirmation must match the pending signup account', async () => {
  const server = accountServer({ signup: { user: { id: 'pending' } } });
  const h = harness({ handler: call => call.url.includes('/auth/v1/verify') ? response({ ...session(), user: { id: 'other', email: 'other@example.test' } }) : server(call) });
  await h.cloud.account.signUp({ email: 'owner@example.test', password: 'test-password' });
  await assert.rejects(h.cloud.account.finishAuthCallback('com.froydinger.breeze://auth-callback?token_hash=attacker&type=signup'), /does not match/); assert.equal(h.cloud.account.state().signedIn, false);
});

test('account deletion requires explicit confirmation and uses the exact native RPC after confirmation', async () => {
  const server = accountServer(), h = harness({ handler: call => call.url.endsWith('/functions/v1/delete-account') ? response({ success: true }) : server(call), initial: { bookmarks: [{ id: 'b', url: 'https://example.com' }], openTabs: [{ id: 't', url: 'https://example.com' }], history: [{ id: 'h' }], chats: [{ id: 'c', messages: [] }], reminders: [{ id: 'r' }], pins: [{ id: 'p' }] } });
  await h.cloud.account.signIn({ email: 'owner@example.test', password: 'test-password' });
  const password = await h.cloud.vault.savePassword({ origin: 'https://example.com', username: 'person', password: 'device-only-password' });
  const before = h.calls.length;
  await assert.rejects(h.cloud.account.deleteAccount(), /Explicit/); await assert.rejects(h.cloud.account.deleteAccount({ confirmed: 'yes' }), /Explicit/); assert.equal(h.calls.length, before);
  const result = await h.cloud.account.deleteAccount({ confirmed: true });
  const call = h.calls.at(-1); assert.equal(call.url, 'https://account.example.test/functions/v1/delete-account'); assert.equal(call.options.method, 'POST'); assert.deepEqual(call.body, {});
  assert.equal(call.options.headers.Authorization, 'Bearer user-access-secret'); assert.equal(call.options.headers.apikey, config.supabaseAnonKey);
  assert.equal(result.signedIn, false); assert.equal(result.status, 'Breeze account deleted'); assert.equal(result.deletingAccount, false);
  for (const name of ['bookmarks', 'openTabs', 'history', 'chats', 'reminders']) assert.deepEqual(h.store.data[name], []);
  assert.equal(h.store.data.pins.length, 1); assert.equal((await h.cloud.vault.revealPassword(password.id)).password, 'device-only-password');
  assert.equal(await h.cloud.vault.get('cloudSession'), null); assert.equal(await h.cloud.vault.get('cloudSyncState'), null);
});
test('failed account deletion preserves local collections and encrypted session without automatic retry', async () => {
  const server = accountServer(), h = harness({ handler: call => call.url.endsWith('/functions/v1/delete-account') ? response({ error: 'Service unavailable' }, 503) : server(call), initial: { bookmarks: [{ id: 'b', url: 'https://example.com' }] } });
  await h.cloud.account.signIn({ email: 'owner@example.test', password: 'test-password' });
  await assert.rejects(h.cloud.account.deleteAccount({ confirmed: true }), /Service unavailable/);
  assert.equal(h.cloud.account.state().signedIn, true); assert.equal(h.store.data.bookmarks.length, 1); assert.ok(await h.cloud.vault.get('cloudSession'));
  assert.equal(h.calls.filter(call => call.url.endsWith('/functions/v1/delete-account')).length, 1); assert.match(h.cloud.account.state().status, /could not be confirmed/);
});
test('account deletion blocks concurrent deletion/sync while RPC is pending', async () => {
  let release, started; const start = new Promise(resolve => { started = resolve; }), server = accountServer();
  const h = harness({ handler: async call => { if (call.url.endsWith('/functions/v1/delete-account')) { started(); await new Promise(resolve => { release = resolve; }); return response({ success: true }); } return server(call); } });
  await h.cloud.account.signIn({ email: 'owner@example.test', password: 'test-password' });
  const pending = h.cloud.account.deleteAccount({ confirmed: true }); await start;
  assert.equal(h.cloud.account.state().deletingAccount, true); await assert.rejects(h.cloud.account.deleteAccount({ confirmed: true }), /already in progress/); await assert.rejects(h.cloud.account.syncNow(), /already in progress/);
  release(); await pending; assert.equal(h.calls.filter(call => call.url.endsWith('/functions/v1/delete-account')).length, 1);
});
test('cloud export matches native shape, defaults missing collections, excludes secrets and is read-only', async () => {
  const collections = { bookmarks: { formatVersion: 1, entries: [{ id: 'b', title: 'Example', url: 'https://example.com', time: 123 }], deletedIds: [] } };
  const h = harness({ handler: accountServer({ collections }) }); await h.cloud.account.signIn({ email: 'owner@example.test', password: 'test-password' });
  await h.cloud.vault.savePassword({ origin: 'https://example.com', username: 'person', password: 'device-password' });
  const before = h.calls.length, result = await h.cloud.account.exportCloudData();
  assert.equal(result.format, 'Breeze Cloud export'); assert.equal(result.account, 'owner@example.test'); assert.equal(result.exportedAt, '2027-01-15T08:00:00.000Z');
  assert.deepEqual(Object.keys(result.collections), ['bookmarks', 'tabs', 'history', 'chats', 'reminders']); assert.deepEqual(result.collections.bookmarks, collections.bookmarks); assert.deepEqual(result.collections.tabs, { formatVersion: 1, entries: [], deletedIds: [] });
  assert.ok(h.calls.slice(before).every(call => call.options.method === 'GET')); assert.ok(!JSON.stringify(result).includes('device-password')); assert.ok(!JSON.stringify(result).includes('user-access-secret')); assert.ok(!JSON.stringify(result).includes('user-refresh-secret'));
});
