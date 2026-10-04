'use strict';

// Configuration is materialized only at build time, never committed or printed.
// The client token is an existing Breeze Cloud client credential, not a provider key.
const fs = require('node:fs');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '../..');
const OUTPUT = path.resolve(__dirname, '../config.generated.json');
const AI_ORIGIN = 'https://breeze-chat.jakefroydinger.workers.dev';
const SUPABASE_ORIGIN = 'https://sbvjjseitpahdpewsqqc.supabase.co';
const REDIRECT_URI = 'com.froydinger.breeze://auth-callback';

function developmentConfig() {
  // An isolated test build must never discover or embed production credentials.
  return { development: true, aiBaseURL: '', aiClientToken: '', supabaseURL: '',
    supabaseAnonKey: '', redirectURI: 'com.froydinger.breeze.test://auth-callback' };
}

function readFirstFile(paths) {
  for (const file of paths) {
    try { return fs.readFileSync(file, 'utf8').trim(); }
    catch (error) { if (error.code !== 'ENOENT') throw new Error('Could not read local Breeze Cloud configuration.'); }
  }
  return '';
}

function requireOrigin(value, expected, label) {
  let url;
  try { url = new URL(value); } catch { throw new Error(`${label} must use the existing Breeze service HTTPS URL.`); }
  if (url.origin !== expected || url.protocol !== 'https:' || url.username || url.password ||
      url.search || url.hash || (url.pathname !== '/' && url.pathname !== '')) {
    throw new Error(`${label} must use the existing Breeze service HTTPS URL.`);
  }
  return url.origin;
}

function validatePublicKey(key) {
  if (!key) throw new Error('Missing BREEZE_CLOUD_SUPABASE_ANON_KEY. An existing public Supabase key is required.');
  if (key.startsWith('sb_publishable_') && /^sb_publishable_[A-Za-z0-9_-]{20,}$/.test(key)) return key;
  const pieces = key.split('.');
  if (pieces.length !== 3 || !pieces.every(piece => /^[A-Za-z0-9_-]+$/.test(piece))) {
    throw new Error('BREEZE_CLOUD_SUPABASE_ANON_KEY must be an existing anon or publishable key, never a secret key.');
  }
  let payload;
  try { payload = JSON.parse(Buffer.from(pieces[1], 'base64url').toString('utf8')); }
  catch { throw new Error('BREEZE_CLOUD_SUPABASE_ANON_KEY has an invalid public-key payload.'); }
  if (payload.role !== 'anon' || payload.ref !== new URL(SUPABASE_ORIGIN).hostname.split('.')[0]) {
    throw new Error('BREEZE_CLOUD_SUPABASE_ANON_KEY must be the existing project anon key, never a service-role key.');
  }
  if (payload.exp && (!Number.isFinite(payload.exp) || payload.exp * 1000 <= Date.now())) {
    throw new Error('The configured Supabase public key has expired.');
  }
  return key;
}

function validateConfig(config) {
  if (config.development) throw new Error('An unconfigured development build cannot pass production configuration validation.');
  const validated = {
    aiBaseURL: requireOrigin(config.aiBaseURL, AI_ORIGIN, 'BREEZE_CLOUD_AI_BASE_URL'),
    aiClientToken: String(config.aiClientToken || '').trim(),
    supabaseURL: requireOrigin(config.supabaseURL, SUPABASE_ORIGIN, 'BREEZE_CLOUD_SUPABASE_URL'),
    supabaseAnonKey: validatePublicKey(String(config.supabaseAnonKey || '').trim()),
    redirectURI: config.redirectURI || REDIRECT_URI
  };
  if (!validated.aiClientToken) throw new Error('Missing BREEZE_CLOUD_CLIENT_TOKEN. An existing Breeze Cloud client token is required.');
  if (validated.aiClientToken.length < 16 || validated.aiClientToken.length > 4096 ||
      !/^[A-Za-z0-9._~+/=-]+$/.test(validated.aiClientToken) ||
      /^(?:changeme|placeholder|example|your[-_]?token|test[-_]?token|dummy)/i.test(validated.aiClientToken)) {
    throw new Error('BREEZE_CLOUD_CLIENT_TOKEN must contain a valid existing client token.');
  }
  if (validated.redirectURI !== REDIRECT_URI) throw new Error('BREEZE_CLOUD_REDIRECT_URI must match the existing Breeze auth callback.');
  return validated;
}

function loadConfig({ env = process.env, repoRoot = REPO_ROOT, development = false } = {}) {
  if (development) return developmentConfig();
  const token = String(env.BREEZE_CLOUD_CLIENT_TOKEN || '').trim() || readFirstFile([
    path.join(repoRoot, 'cloudflare/breeze-chat-worker/.breeze-client-token')
  ]);
  const publicKey = String(env.BREEZE_CLOUD_SUPABASE_ANON_KEY || '').trim() || readFirstFile([
    path.join(repoRoot, 'native/.supabase-anon-key'), path.join(repoRoot, '.supabase-anon-key')
  ]);
  const missing = [];
  if (!token) missing.push('BREEZE_CLOUD_CLIENT_TOKEN');
  if (!publicKey) missing.push('BREEZE_CLOUD_SUPABASE_ANON_KEY');
  if (missing.length) throw new Error(`Missing existing build configuration: ${missing.join(', ')}.`);
  return validateConfig({
    aiBaseURL: env.BREEZE_CLOUD_AI_BASE_URL || AI_ORIGIN,
    aiClientToken: token,
    supabaseURL: env.BREEZE_CLOUD_SUPABASE_URL || SUPABASE_ORIGIN,
    supabaseAnonKey: publicKey,
    redirectURI: env.BREEZE_CLOUD_REDIRECT_URI || REDIRECT_URI
  });
}

async function verifyNetwork(config, fetchImpl = globalThis.fetch) {
  if (config.development) throw new Error('Development builds cannot verify or contact Cloud services.');
  // Fail closed on redirects so credentials can never follow a redirect to another host.
  async function check(url, headers, expected, label) {
    try {
      const response = await fetchImpl(url, { headers, redirect: 'error', signal: AbortSignal.timeout(15000) });
      if (!response.ok) throw new Error('rejected');
      const json = await response.json();
      if (!expected(json)) throw new Error('unexpected response');
    } catch {
      // Deliberately omit exception text, URLs, response bodies and header values.
      throw new Error(`${label} verification failed. Check the existing service configuration and connectivity.`);
    }
  }
  await check(`${config.aiBaseURL}/health`, { Authorization: `Bearer ${config.aiClientToken}` },
    body => body && body.ok === true, 'Breeze Cloud');
  await check(`${config.supabaseURL}/auth/v1/settings`, { apikey: config.supabaseAnonKey },
    body => body && typeof body.external === 'object' && body.external !== null, 'Supabase public key');
}

async function main(args = process.argv.slice(2)) {
  const accepted = new Set(['--check', '--verify-network', '--development']);
  if (args.some(arg => !accepted.has(arg))) throw new Error('Usage: node scripts/build-config.cjs [--check] [--verify-network | --development]');
  const development = args.includes('--development');
  if (development && args.includes('--verify-network')) throw new Error('--development cannot be combined with --verify-network.');
  const checkOnly = args.includes('--check');
  if (!checkOnly) fs.rmSync(OUTPUT, { force: true }); // Never leave a previous build's credential in use after failure.
  const config = loadConfig({ development });
  if (args.includes('--verify-network')) await verifyNetwork(config);
  if (!checkOnly) {
    fs.writeFileSync(OUTPUT, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
  }
  console.log(development ? 'Unconfigured Breeze Test configuration created. Cloud and Aero are disabled; no credentials were read.' : args.includes('--verify-network')
    ? 'Breeze Cloud build configuration and service connectivity verified. Values are not logged.'
    : 'Breeze Cloud build configuration validated. Values are not logged.');
}

module.exports = { developmentConfig, loadConfig, validateConfig, validatePublicKey, verifyNetwork, main };
if (require.main === module) {
  main().catch(error => { console.error(`Build configuration error: ${error.message}`); process.exitCode = 1; });
}
