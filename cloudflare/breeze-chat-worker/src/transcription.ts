interface TranscriptionEnv {
  AI_PROVIDER_API_KEY?: string;
  OPENAI_API_KEY?: string;
}

interface Dependencies {
  json: (data: unknown, status?: number) => Response;
  checkQuota: () => Promise<{ quotaResp: Response; quota: Record<string, unknown> }>;
}

const MAX_AUDIO_BYTES = 8 * 1024 * 1024;

export async function proxyMobileTranscription(req: Request, env: TranscriptionEnv, deps: Dependencies): Promise<Response> {
  const key = (env.AI_PROVIDER_API_KEY || env.OPENAI_API_KEY || "").trim();
  if (!key) return deps.json({ error: "provider_not_configured" }, 500);
  const length = Number(req.headers.get("Content-Length") || "0");
  if (length > MAX_AUDIO_BYTES) return deps.json({ error: "audio_too_large" }, 413);
  const type = req.headers.get("Content-Type")?.split(";")[0].trim().toLowerCase();
  if (type !== "audio/mp4" && type !== "audio/m4a") return deps.json({ error: "unsupported_audio" }, 415);

  const reader = req.body?.getReader();
  if (!reader) return deps.json({ error: "missing_audio" }, 400);
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const part = await reader.read();
      if (part.done) break;
      size += part.value.byteLength;
      if (size > MAX_AUDIO_BYTES) {
        await reader.cancel();
        return deps.json({ error: "audio_too_large" }, 413);
      }
      chunks.push(part.value);
    }
  } catch {
    return deps.json({ error: "invalid_audio" }, 400);
  }
  if (size < 128) return deps.json({ error: "audio_too_short" }, 400);

  const { quotaResp, quota } = await deps.checkQuota();
  if (!quotaResp.ok) return deps.json(quota, quotaResp.status);

  const audio = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { audio.set(chunk, offset); offset += chunk.byteLength; }
  const form = new FormData();
  form.set("model", "gpt-transcribe");
  form.set("file", new File([audio], "breeze-voice.m4a", { type: "audio/mp4" }));

  let upstream: Response;
  try {
    upstream = await fetch("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}` },
      body: form,
      signal: AbortSignal.timeout(90_000),
    });
  } catch {
    return deps.json({ error: "transcription_unavailable" }, 502);
  }
  if (!upstream.ok) return deps.json({ error: "transcription_failed" }, upstream.status === 429 ? 429 : 502);
  let result: unknown;
  try { result = await upstream.json(); } catch { return deps.json({ error: "invalid_provider_response" }, 502); }
  const text = (result as { text?: unknown })?.text;
  if (typeof text !== "string") return deps.json({ error: "invalid_provider_response" }, 502);
  return deps.json({ text: text.slice(0, 12_000).trim() });
}
