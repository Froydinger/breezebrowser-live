interface Env {
  OPENAI_API_KEY: string;
  OPENAI_CHAT_MODEL: string;
  OPENAI_IMAGE_MODEL: string;
  MAX_OUTPUT_TOKENS: string;
  CHAT_DAILY_LIMIT: string;
  IMAGE_DAILY_LIMIT: string;
  BREEZE_CLIENT_TOKEN?: string;
  QUOTA: DurableObjectNamespace<QuotaTracker>;
}

type QuotaKind = "chat" | "image";

interface QuotaState {
  day: string;
  chat: number;
  image: number;
  seenChat: string[];
  seenImage: string[];
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Authorization, Content-Type, X-Breeze-Client-Id, X-Breeze-Request-Id",
  "Cache-Control": "no-store",
};

export class QuotaTracker {
  constructor(private state: DurableObjectState, private env: Env) {}

  async fetch(req: Request): Promise<Response> {
    const { kind, requestId } = await req.json<{ kind: QuotaKind; requestId?: string }>();
    const day = new Date().toISOString().slice(0, 10);
    const limit = kind === "image"
      ? intEnv(this.env.IMAGE_DAILY_LIMIT, 10)
      : intEnv(this.env.CHAT_DAILY_LIMIT, 30);

    let quota = await this.state.storage.get<QuotaState>("quota");
    if (!quota || quota.day !== day) {
      quota = { day, chat: 0, image: 0, seenChat: [], seenImage: [] };
    }

    const seenKey = kind === "image" ? "seenImage" : "seenChat";
    const countKey = kind;
    const seen = quota[seenKey];
    const uniqueId = (requestId || "").trim();
    const alreadyCounted = uniqueId.length > 0 && seen.includes(uniqueId);

    if (!alreadyCounted) {
      if (quota[countKey] >= limit) {
        return Response.json({
          ok: false,
          kind,
          limit,
          used: quota[countKey],
          remaining: 0,
          error: `Daily ${kind} limit reached.`,
        }, { status: 429 });
      }

      quota[countKey] += 1;
      if (uniqueId) {
        seen.push(uniqueId);
        if (seen.length > 100) seen.splice(0, seen.length - 100);
      }
      await this.state.storage.put("quota", quota);
    }

    return Response.json({
      ok: true,
      kind,
      limit,
      used: quota[countKey],
      remaining: Math.max(0, limit - quota[countKey]),
    });
  }
}

function json(data: unknown, status = 200) {
  return Response.json(data, { status, headers: corsHeaders });
}

function isAuthorized(req: Request, env: Env) {
  if (!env.BREEZE_CLIENT_TOKEN) return true;
  const expected = `Bearer ${env.BREEZE_CLIENT_TOKEN}`;
  return req.headers.get("Authorization") === expected;
}

function intEnv(value: string | undefined, fallback: number) {
  const parsed = Number.parseInt(value || "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function clientIdFor(req: Request) {
  const explicit = req.headers.get("X-Breeze-Client-Id")?.trim();
  if (explicit) return explicit.slice(0, 128);
  const ip = req.headers.get("CF-Connecting-IP")?.trim();
  return ip ? `ip:${ip}` : "anonymous";
}

async function checkQuota(req: Request, env: Env, kind: QuotaKind) {
  const clientId = clientIdFor(req);
  const id = env.QUOTA.idFromName(clientId);
  const stub = env.QUOTA.get(id);
  const quotaResp = await stub.fetch("https://quota.local/check", {
    method: "POST",
    body: JSON.stringify({
      kind,
      requestId: req.headers.get("X-Breeze-Request-Id") || "",
    }),
  });
  const quota = await quotaResp.json<Record<string, unknown>>();
  return { quotaResp, quota };
}

function withQuotaHeaders(resp: Response, quota: Record<string, unknown>) {
  const headers = new Headers(corsHeaders);
  headers.set("Content-Type", resp.headers.get("Content-Type") || "application/json");
  for (const [key, value] of Object.entries(quota)) {
    if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
      headers.set(`X-Breeze-Quota-${key}`, String(value));
    }
  }
  return new Response(resp.body, { status: resp.status, headers });
}

function allowedSize(raw: unknown) {
  const value = typeof raw === "string" ? raw : "1024x1024";
  if (value === "auto") return value;
  const match = value.match(/^(\d{3,4})x(\d{3,4})$/);
  if (!match) return "1024x1024";
  const width = Number(match[1]);
  const height = Number(match[2]);
  if (width % 16 !== 0 || height % 16 !== 0) return "1024x1024";
  if (width < 256 || height < 256 || width > 3840 || height > 3840) return "1024x1024";
  const ratio = Math.max(width, height) / Math.min(width, height);
  if (ratio > 3) return "1024x1024";
  const pixels = width * height;
  if (pixels < 655_360 || pixels > 8_294_400) return "1024x1024";
  return value;
}

async function proxyChat(req: Request, env: Env) {
  let body: Record<string, unknown>;
  try {
    body = await req.json<Record<string, unknown>>();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  if (!Array.isArray(body.messages)) {
    return json({ error: "missing_messages" }, 400);
  }

  const { quotaResp, quota } = await checkQuota(req, env, "chat");
  if (!quotaResp.ok) return json(quota, quotaResp.status);

  const configuredMax = intEnv(env.MAX_OUTPUT_TOKENS, 1200);
  const requestedMax = Number.parseInt(String(body.max_completion_tokens ?? configuredMax), 10);
  const maxCompletionTokens = Math.min(
    Number.isFinite(requestedMax) && requestedMax > 0 ? requestedMax : configuredMax,
    configuredMax,
  );

  const upstream = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: env.OPENAI_CHAT_MODEL || "gpt-5.4-mini",
      messages: body.messages,
      max_completion_tokens: maxCompletionTokens,
      reasoning_effort: "low",
    }),
  });

  return withQuotaHeaders(upstream, quota);
}

async function proxyImageGeneration(req: Request, env: Env) {
  let body: Record<string, unknown>;
  try {
    body = await req.json<Record<string, unknown>>();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  if (typeof body.prompt !== "string" || !body.prompt.trim()) {
    return json({ error: "missing_prompt" }, 400);
  }

  const { quotaResp, quota } = await checkQuota(req, env, "image");
  if (!quotaResp.ok) return json(quota, quotaResp.status);

  const upstream = await fetch("https://api.openai.com/v1/images/generations", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: env.OPENAI_IMAGE_MODEL || "gpt-image-2",
      prompt: body.prompt,
      n: 1,
      quality: "low",
      size: allowedSize(body.size),
      output_format: "png",
    }),
  });

  return withQuotaHeaders(upstream, quota);
}

async function proxyImageEdit(req: Request, env: Env) {
  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return json({ error: "invalid_form_data" }, 400);
  }

  const prompt = String(form.get("prompt") || "").trim();
  if (!prompt) return json({ error: "missing_prompt" }, 400);

  const images = form.getAll("image").filter((value) => value instanceof File);
  if (images.length === 0) return json({ error: "missing_image" }, 400);

  const { quotaResp, quota } = await checkQuota(req, env, "image");
  if (!quotaResp.ok) return json(quota, quotaResp.status);

  const upstreamForm = new FormData();
  upstreamForm.set("model", env.OPENAI_IMAGE_MODEL || "gpt-image-2");
  upstreamForm.set("prompt", prompt);
  upstreamForm.set("n", "1");
  upstreamForm.set("quality", "low");
  upstreamForm.set("size", allowedSize(form.get("size")));
  upstreamForm.set("output_format", "png");
  for (const image of images) upstreamForm.append("image", image);
  const mask = form.get("mask");
  if (mask instanceof File) upstreamForm.set("mask", mask);

  const upstream = await fetch("https://api.openai.com/v1/images/edits", {
    method: "POST",
    headers: { Authorization: `Bearer ${env.OPENAI_API_KEY}` },
    body: upstreamForm,
  });

  return withQuotaHeaders(upstream, quota);
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    if (!isAuthorized(req, env)) {
      return json({ error: "unauthorized" }, 401);
    }

    const path = new URL(req.url).pathname;
    if (req.method === "GET" && path === "/health") return json({ ok: true });
    if (req.method !== "POST") return json({ error: "not_found" }, 404);
    if (path === "/v1/chat/completions") return proxyChat(req, env);
    if (path === "/v1/images/generations") return proxyImageGeneration(req, env);
    if (path === "/v1/images/edits") return proxyImageEdit(req, env);
    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
