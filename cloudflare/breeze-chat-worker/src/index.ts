interface Env {
  AI_PROVIDER_API_KEY?: string;
  OPENAI_API_KEY?: string;        // legacy secret; used as a fallback for the key
  AI_CHAT_ENDPOINT: string;
  AI_CHAT_MODEL: string;
  MAX_OUTPUT_TOKENS: string;
  CHAT_DAILY_LIMIT: string;
  BREEZE_CLIENT_TOKEN?: string;
  QUOTA: DurableObjectNamespace<QuotaTracker>;
}

type QuotaKind = "chat";

interface QuotaState {
  day: string;
  chat: number;
  seenChat: string[];
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
    const limit = intEnv(this.env.CHAT_DAILY_LIMIT, 30);

    let quota = await this.state.storage.get<QuotaState>("quota");
    if (!quota || quota.day !== day) {
      quota = { day, chat: 0, seenChat: [] };
    }

    const seen = quota.seenChat;
    const uniqueId = (requestId || "").trim();
    const alreadyCounted = uniqueId.length > 0 && seen.includes(uniqueId);

    if (!alreadyCounted) {
      if (quota.chat >= limit) {
        return Response.json({
          ok: false,
          kind,
          limit,
          used: quota.chat,
          remaining: 0,
          error: `Daily ${kind} limit reached.`,
        }, { status: 429 });
      }

      quota.chat += 1;
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
      used: quota.chat,
      remaining: Math.max(0, limit - quota.chat),
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

function requiredEnv(value: string | undefined, name: string) {
  const trimmed = (value || "").trim();
  if (!trimmed) throw new Error(`missing_${name}`);
  return trimmed;
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

  const configuredMax = intEnv(env.MAX_OUTPUT_TOKENS, 2400);
  const requestedMax = Number.parseInt(String(body.max_completion_tokens ?? configuredMax), 10);
  const maxCompletionTokens = Math.min(
    Number.isFinite(requestedMax) && requestedMax > 0 ? requestedMax : configuredMax,
    configuredMax,
  );

  let endpoint: string;
  let providerKey: string;
  let providerModel: string;
  try {
    endpoint = requiredEnv(env.AI_CHAT_ENDPOINT, "AI_CHAT_ENDPOINT");
    providerKey = requiredEnv(env.AI_PROVIDER_API_KEY || env.OPENAI_API_KEY, "AI_PROVIDER_API_KEY");
    providerModel = requiredEnv(env.AI_CHAT_MODEL, "AI_CHAT_MODEL");
  } catch {
    return json({ error: "provider_not_configured" }, 500);
  }

  const upstream = await fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${providerKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: providerModel,
      messages: body.messages,
      max_completion_tokens: maxCompletionTokens,
      reasoning_effort: "low",
    }),
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
    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
