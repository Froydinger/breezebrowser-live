// Local, on-device image generation — SD-Turbo via onnxruntime-node.
// Single-step (Euler, no CFG) so it's fast enough to run on Apple Silicon CPU/
// CoreML without a Python/native-SD dependency. Models download once to
// userData/models/sd-turbo (like the LLM). 100% local — nothing leaves the Mac.
//
// NOTE (2.4 WIP): the scheduler/latent math follows the standard onnxruntime-web
// SD-Turbo reference pipeline. The exact model export (hidden-state layer, fp16
// vs fp32, scaling) must be verified with a real generation on-device; constants
// are centralized below so we can tune them after the first test run.

const fs = require('fs');
const path = require('path');
const https = require('https');

// ---- model manifest -------------------------------------------------------
// fp16 ONNX export purpose-built for in-browser/onnx use (same files the
// onnxruntime-web SD-Turbo demo uses). Each entry may have an external weights
// file (.onnx_data) that ORT loads automatically when it sits beside the .onnx.
const HF_BASE = 'https://huggingface.co/schmuell/sd-turbo-ort-web/resolve/main';
const MODEL_FILES = [
  { rel: 'text_encoder/model.onnx', url: `${HF_BASE}/text_encoder/model.onnx` },
  { rel: 'unet/model.onnx', url: `${HF_BASE}/unet/model.onnx` },
  { rel: 'unet/model.onnx_data', url: `${HF_BASE}/unet/model.onnx_data`, optional: true },
  { rel: 'vae_decoder/model.onnx', url: `${HF_BASE}/vae_decoder/model.onnx` },
];
const TOKENIZER_ID = 'Xenova/sd-turbo'; // CLIP tokenizer (transformers.js caches it)

// ---- pipeline constants (tune after first on-device test) ------------------
const LATENT_W = 64, LATENT_H = 64;      // 512x512 output
const SIGMA = 14.6146;                    // Euler init sigma for SD-Turbo 1-step
const VAE_SCALE = 0.18215;
const MAX_TOKENS = 77;

let ort = null;
let AutoTokenizer = null;
const ai = { sessions: null, tokenizer: null, loading: false };

function modelsDir(userDataPath) {
  return path.join(userDataPath, 'models', 'sd-turbo');
}

function isInstalled(userDataPath) {
  const dir = modelsDir(userDataPath);
  return MODEL_FILES.filter((f) => !f.optional).every((f) =>
    fs.existsSync(path.join(dir, f.rel)));
}

// ---- float16 helpers (fp16 model I/O) -------------------------------------
function f32ToF16(val) {
  // IEEE 754 half from float; returns Uint16
  const f = new Float32Array(1); f[0] = val;
  const i = new Int32Array(f.buffer)[0];
  const sign = (i >> 16) & 0x8000;
  let exp = ((i >> 23) & 0xff) - 127 + 15;
  let mant = i & 0x7fffff;
  if (exp <= 0) return sign; // underflow → 0
  if (exp >= 0x1f) return sign | 0x7c00; // overflow → inf
  return sign | (exp << 10) | (mant >> 13);
}
const _i32 = new Int32Array(1);
const _f32 = new Float32Array(_i32.buffer);
function bitsToFloat(bits) { _i32[0] = bits; return _f32[0]; }
function f16ToF32(h) {
  const sign = (h & 0x8000) << 16;
  let exp = (h >> 10) & 0x1f;
  let mant = h & 0x3ff;
  if (exp === 0) {
    if (mant === 0) return bitsToFloat(sign); // +/- 0
    exp = 1;
    while (!(mant & 0x400)) { mant <<= 1; exp--; } // subnormal → normalize
    mant &= 0x3ff;
  } else if (exp === 0x1f) {
    return bitsToFloat(sign | 0x7f800000 | (mant << 13)); // inf / nan
  }
  return bitsToFloat(sign | ((exp + 112) << 23) | (mant << 13));
}
const toF16Array = (f32) => { const u = new Uint16Array(f32.length); for (let i = 0; i < f32.length; i++) u[i] = f32ToF16(f32[i]); return u; };
const fromF16Array = (u16) => { const f = new Float32Array(u16.length); for (let i = 0; i < u16.length; i++) f[i] = f16ToF32(u16[i]); return f; };

function randn(n, scale = 1) {
  const out = new Float32Array(n);
  for (let i = 0; i < n; i += 2) {
    const u1 = Math.random() || 1e-7, u2 = Math.random();
    const r = Math.sqrt(-2 * Math.log(u1));
    out[i] = r * Math.cos(2 * Math.PI * u2) * scale;
    if (i + 1 < n) out[i + 1] = r * Math.sin(2 * Math.PI * u2) * scale;
  }
  return out;
}

// ---- download -------------------------------------------------------------
function download(url, dest, onProgress) {
  return new Promise((resolve, reject) => {
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const tmp = dest + '.part';
    const file = fs.createWriteStream(tmp);
    const req = https.get(url, { headers: { 'user-agent': 'Breeze' } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        file.close(); fs.rmSync(tmp, { force: true });
        return download(res.headers.location, dest, onProgress).then(resolve, reject);
      }
      if (res.statusCode !== 200) { file.close(); fs.rmSync(tmp, { force: true }); return reject(new Error(`HTTP ${res.statusCode} for ${url}`)); }
      const total = parseInt(res.headers['content-length'] || '0', 10);
      let got = 0;
      res.on('data', (c) => { got += c.length; if (total) onProgress?.(got / total); });
      res.pipe(file);
      file.on('finish', () => file.close(() => { fs.renameSync(tmp, dest); resolve(); }));
    });
    req.on('error', (e) => { file.close(); fs.rmSync(tmp, { force: true }); reject(e); });
  });
}

// Download all model files, reporting overall progress 0..1.
async function ensureDownloaded(userDataPath, onProgress) {
  const dir = modelsDir(userDataPath);
  const needed = MODEL_FILES.filter((f) => !fs.existsSync(path.join(dir, f.rel)));
  for (let i = 0; i < needed.length; i++) {
    const f = needed[i];
    try {
      await download(f.url, path.join(dir, f.rel), (p) =>
        onProgress?.((i + p) / needed.length));
    } catch (e) {
      if (!f.optional) throw e;
    }
  }
  onProgress?.(1);
}

async function loadSessions(userDataPath) {
  if (ai.sessions) return;
  ort = ort || require('onnxruntime-node');
  if (!AutoTokenizer) ({ AutoTokenizer } = await import('@huggingface/transformers'));
  const dir = modelsDir(userDataPath);
  const opt = { executionProviders: ['cpu'] }; // coreml can be added after testing
  ai.sessions = {
    text: await ort.InferenceSession.create(path.join(dir, 'text_encoder/model.onnx'), opt),
    unet: await ort.InferenceSession.create(path.join(dir, 'unet/model.onnx'), opt),
    vae: await ort.InferenceSession.create(path.join(dir, 'vae_decoder/model.onnx'), opt),
  };
  ai.tokenizer = await AutoTokenizer.from_pretrained(TOKENIZER_ID);
}

// Main entry: returns a PNG data URL. onProgress(stage, frac).
async function generate(userDataPath, prompt, onProgress) {
  if (ai.loading) throw new Error('Image model is busy.');
  ai.loading = true;
  try {
    if (!isInstalled(userDataPath)) {
      onProgress?.('downloading', 0);
      await ensureDownloaded(userDataPath, (p) => onProgress?.('downloading', p));
    }
    onProgress?.('loading');
    await loadSessions(userDataPath);
    onProgress?.('generating');

    const { Tensor } = ort;

    // 1) tokenize + text encode
    const enc = await ai.tokenizer(prompt, { padding: 'max_length', max_length: MAX_TOKENS, truncation: true });
    const ids = BigInt64Array.from(Array.from(enc.input_ids.data, (x) => BigInt(x)));
    const textOut = await ai.sessions.text.run({
      input_ids: new Tensor('int64', ids, [1, MAX_TOKENS]),
    });
    const hidden = textOut[ai.sessions.text.outputNames[0]]; // last_hidden_state

    // 2) latents
    const latentLen = 4 * LATENT_H * LATENT_W;
    let latents = randn(latentLen, SIGMA);
    const scaled = new Float32Array(latentLen);
    const denom = Math.sqrt(SIGMA * SIGMA + 1);
    for (let i = 0; i < latentLen; i++) scaled[i] = latents[i] / denom;

    // 3) one UNet step (fp16 I/O for this export)
    const sampleT = new Tensor('float16', toF16Array(scaled), [1, 4, LATENT_H, LATENT_W]);
    const tT = new Tensor('float16', toF16Array(new Float32Array([999])), [1]);
    const hiddenT = hidden.type === 'float16'
      ? hidden
      : new Tensor('float16', toF16Array(hidden.data), hidden.dims);
    const unetOut = await ai.sessions.unet.run({
      sample: sampleT, timestep: tT, encoder_hidden_states: hiddenT,
    });
    const noise = fromF16Array(unetOut[ai.sessions.unet.outputNames[0]].data);

    // Euler 1-step (epsilon): denoised = latents - sigma * noise
    const denoised = new Float32Array(latentLen);
    for (let i = 0; i < latentLen; i++) denoised[i] = (latents[i] - SIGMA * noise[i]) / VAE_SCALE;

    // 4) VAE decode → [1,3,512,512] in [-1,1]
    const vaeOut = await ai.sessions.vae.run({
      latent_sample: new Tensor('float16', toF16Array(denoised), [1, 4, LATENT_H, LATENT_W]),
    });
    const imgTensor = vaeOut[ai.sessions.vae.outputNames[0]];
    const img = imgTensor.type === 'float16' ? fromF16Array(imgTensor.data) : imgTensor.data;
    const W = imgTensor.dims[3], H = imgTensor.dims[2];

    // 5) CHW [-1,1] → RGBA PNG
    return encodePNG(img, W, H);
  } finally {
    ai.loading = false;
  }
}

// minimal PNG encoder (RGBA, no deps) from CHW float [-1,1]
function encodePNG(chw, W, H) {
  const zlib = require('zlib');
  const px = Buffer.alloc((W * 4 + 1) * H);
  const plane = W * H;
  for (let y = 0; y < H; y++) {
    px[y * (W * 4 + 1)] = 0; // filter: none
    for (let x = 0; x < W; x++) {
      const i = y * W + x;
      const o = y * (W * 4 + 1) + 1 + x * 4;
      const r = Math.min(255, Math.max(0, Math.round((chw[i] + 1) * 127.5)));
      const g = Math.min(255, Math.max(0, Math.round((chw[plane + i] + 1) * 127.5)));
      const b = Math.min(255, Math.max(0, Math.round((chw[2 * plane + i] + 1) * 127.5)));
      px[o] = r; px[o + 1] = g; px[o + 2] = b; px[o + 3] = 255;
    }
  }
  const idat = zlib.deflateSync(px);
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const t = Buffer.from(type);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(Buffer.concat([t, data])) >>> 0);
    return Buffer.concat([len, t, data, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4);
  ihdr[8] = 8; ihdr[9] = 6; // 8-bit, RGBA
  const png = Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0)),
  ]);
  return 'data:image/png;base64,' + png.toString('base64');
}

let CRC_TABLE = null;
function crc32(buf) {
  if (!CRC_TABLE) {
    CRC_TABLE = new Int32Array(256);
    for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; CRC_TABLE[n] = c; }
  }
  let c = ~0;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return ~c;
}

module.exports = { isInstalled, ensureDownloaded, generate, modelsDir };
