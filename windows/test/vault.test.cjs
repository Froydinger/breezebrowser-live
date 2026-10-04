'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createCipheriv, createDecipheriv, randomBytes } = require('node:crypto');
const { createVault } = require('../lib/vault.cjs');
function store(initial = {}) { const data = structuredClone(initial); return { data, get: (key, fallback) => data[key] ?? fallback, set: (key, value) => { data[key] = structuredClone(value); } }; }
function storage(async = false) {
  const key = Buffer.alloc(32, 27);
  const encrypt = text => { const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, iv); const bytes = Buffer.concat([cipher.update(text, 'utf8'), cipher.final()]); return Buffer.concat([iv, cipher.getAuthTag(), bytes]); };
  const decrypt = buffer => { const decipher = createDecipheriv('aes-256-gcm', key, buffer.subarray(0, 12)); decipher.setAuthTag(buffer.subarray(12, 28)); return Buffer.concat([decipher.update(buffer.subarray(28)), decipher.final()]).toString(); };
  return async ? { isAsyncEncryptionAvailable: async () => true, encryptStringAsync: async text => encrypt(text), decryptStringAsync: async data => ({ result: decrypt(data), shouldReEncrypt: false }) } : { isEncryptionAvailable: () => true, encryptString: encrypt, decryptString: decrypt };
}
test('vault stores session/profile/passwords only inside OS ciphertext', async () => {
  const s = store(), v = createVault({ store: s, safeStorage: storage() });
  await v.set('cloudSession', { access_token: 'private-token', email: 'private@example.com' });
  const row = await v.savePassword({ origin: 'https://example.com/login', username: 'secret-person', password: 'secret-password' });
  const disk = JSON.stringify(s.data);
  for (const secret of ['private-token', 'private@example.com', 'secret-person', 'secret-password']) assert.ok(!disk.includes(secret));
  assert.equal((await v.listPasswords())[0].password, undefined);
  assert.equal((await v.revealPassword(row.id)).password, 'secret-password');
  const reloaded = createVault({ store: s, safeStorage: storage() });
  assert.equal((await reloaded.get('cloudSession')).access_token, 'private-token');
  assert.equal((await reloaded.listPasswords())[0].origin, 'https://example.com');
});
test('async-only safeStorage API is supported', async () => {
  const s = store(), v = createVault({ store: s, safeStorage: storage(true) });
  await v.set('a', 'data'); const reload = createVault({ store: s, safeStorage: storage(true) }); assert.equal(await reload.get('a'), 'data');
});
test('unavailable/basic_text storage fails closed with no plaintext write', async () => {
  for (const safeStorage of [{ isEncryptionAvailable: () => false }, { ...storage(), getSelectedStorageBackend: () => 'basic_text' }]) {
    const s = store(), v = createVault({ store: s, safeStorage });
    await assert.rejects(v.set('session', 'secret'), /secure storage is unavailable/); assert.deepEqual(s.data, {});
  }
});
test('corrupt ciphertext remains untouched and cannot be overwritten', async () => {
  const s = store({ secureVault: { version: 1, ciphertext: 'YWJj' } }), before = JSON.stringify(s.data);
  const v = createVault({ store: s, safeStorage: storage() }); await assert.rejects(v.set('secret', 'value'), /could not be unlocked/); assert.equal(JSON.stringify(s.data), before);
});
test('encryption/store failures do not commit in-memory changes', async () => {
  const s = store(), safeStorage = storage(), v = createVault({ store: s, safeStorage });
  await v.set('a', 1); safeStorage.encryptString = () => { throw new Error('sensitive detail'); };
  await assert.rejects(v.set('a', 2), /secure storage is unavailable/); assert.equal(await v.get('a'), 1);
});
test('concurrent writes serialize without lost data and getters clone', async () => {
  const v = createVault({ store: store(), safeStorage: storage(true) });
  await Promise.all([v.set('a', { n: 1 }), v.set('b', 2)]); const a = await v.get('a'); a.n = 9;
  assert.equal((await v.get('a')).n, 1); assert.equal(await v.get('b'), 2); await v.remove('a'); assert.equal(await v.get('a'), null);
});
test('password update/delete and invalid origins', async () => {
  const v = createVault({ store: store(), safeStorage: storage() });
  const row = await v.savePassword({ origin: 'https://example.com', username: 'person', password: 'old' });
  const update = await v.savePassword({ origin: 'https://example.com/path', username: 'person', password: 'new' }); assert.equal(update.id, row.id);
  await assert.rejects(v.savePassword({ origin: 'file:///tmp/a', username: '', password: 'secret' }), /website/);
  await assert.rejects(v.savePassword({ origin: 'https://user:pass@example.com', username: '', password: 'secret' }), /website/);
  await v.deletePassword(row.id); assert.deepEqual(await v.listPasswords(), []); await assert.rejects(v.revealPassword(row.id), /not found/);
});
module.exports = { store, storage };
