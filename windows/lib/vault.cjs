'use strict';

const { randomUUID } = require('node:crypto');
const clone = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
const unavailable = () => new Error('Windows secure storage is unavailable. Your passwords and account session were not saved.');

/** Main-process only. One OS-encrypted blob; never a plaintext fallback. */
function createVault({ safeStorage, store, now = Date.now, uuid = randomUUID } = {}) {
  if (!store?.get || !store?.set) throw new TypeError('Vault requires a durable get/set store.');
  let values = Object.create(null);
  let queue = Promise.resolve();
  const storageKey = 'secureVault';
  async function available() {
    if (!safeStorage) throw unavailable();
    if (safeStorage.getSelectedStorageBackend?.() === 'basic_text') throw unavailable();
    const ok = safeStorage.isAsyncEncryptionAvailable
      ? await safeStorage.isAsyncEncryptionAvailable()
      : safeStorage.isEncryptionAvailable?.();
    if (!ok) throw unavailable();
  }
  async function encrypt(text) {
    await available();
    return safeStorage.encryptStringAsync ? safeStorage.encryptStringAsync(text) : safeStorage.encryptString(text);
  }
  async function decrypt(bytes) {
    await available();
    const result = safeStorage.decryptStringAsync ? await safeStorage.decryptStringAsync(bytes) : safeStorage.decryptString(bytes);
    return typeof result === 'string' ? result : result.result;
  }
  const ready = (async () => {
    await available();
    const saved = store.get(storageKey, null);
    if (!saved) return;
    try {
      if (saved.version !== 1 || typeof saved.ciphertext !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(saved.ciphertext)) throw new Error();
      const parsed = JSON.parse(await decrypt(Buffer.from(saved.ciphertext, 'base64')));
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error();
      values = Object.assign(Object.create(null), parsed);
    } catch {
      // Keep the original ciphertext intact if the Windows profile/key is unavailable.
      throw new Error('This encrypted vault could not be unlocked by this Windows profile. No saved data was overwritten.');
    }
  })();
  // A vault can be created before its caller is ready to await it.
  ready.catch(() => {});
  function serial(fn) {
    const next = queue.then(async () => { await ready; return fn(); });
    queue = next.catch(() => {});
    return next;
  }
  async function commit(next) {
    let ciphertext;
    try { ciphertext = await encrypt(JSON.stringify(next)); }
    catch { throw unavailable(); }
    // Atomic/durable store.set is part of the host contract. Do not mutate memory on failure.
    store.set(storageKey, { version: 1, ciphertext: Buffer.from(ciphertext).toString('base64') });
    values = next;
  }
  const api = {
    ready,
    get(key, fallback = null) { return serial(() => clone(Object.hasOwn(values, key) ? values[key] : fallback)); },
    set(key, value) { return serial(async () => { const next = Object.assign(Object.create(null), values, { [key]: clone(value) }); await commit(next); }); },
    remove(key) { return serial(async () => { const next = Object.assign(Object.create(null), values); delete next[key]; await commit(next); }); },
    listPasswords() { return serial(() => (values.passwords || []).map(({ password, ...metadata }) => clone(metadata))); },
    savePassword(input) {
      return serial(async () => {
        let url;
        try { url = new URL(input.origin || input.url); } catch { throw new Error('Enter a valid website address.'); }
        if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) throw new Error('Passwords can only be saved for a website.');
        if (typeof input.username !== 'string' || typeof input.password !== 'string' || !input.password || input.password.length > 16000) throw new Error('Enter a username and password.');
        const rows = clone(values.passwords || []);
        const prior = input.id ? rows.find(row => row.id === input.id) : rows.find(row => row.origin === url.origin && row.username === input.username);
        if (input.id && !prior) throw new Error('Saved password not found.');
        const row = { id: prior?.id || uuid(), origin: url.origin, username: input.username.slice(0, 1000), password: input.password, updatedAt: now() };
        const index = rows.findIndex(item => item.id === row.id);
        if (index < 0) rows.push(row); else rows[index] = row;
        await commit(Object.assign(Object.create(null), values, { passwords: rows }));
        const { password, ...metadata } = row;
        return metadata;
      });
    },
    revealPassword(id) { return serial(() => { const row = (values.passwords || []).find(item => item.id === id); if (!row) throw new Error('Saved password not found.'); return clone(row); }); },
    deletePassword(id) { return serial(async () => { const rows = (values.passwords || []).filter(row => row.id !== id); await commit(Object.assign(Object.create(null), values, { passwords: rows })); }); }
  };
  return Object.freeze(api);
}

module.exports = { createVault };
