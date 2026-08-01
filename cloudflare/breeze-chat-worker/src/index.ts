interface Env {
  AI_PROVIDER_API_KEY?: string;
  OPENAI_API_KEY?: string;        // legacy secret; used as a fallback for the key
  AI_CHAT_ENDPOINT: string;
  AI_CHAT_MODEL: string;
  AI_REALTIME_MODEL?: string;
  AI_REASONING_EFFORT?: string;
  MAX_OUTPUT_TOKENS: string;
  CHAT_DAILY_LIMIT: string;
  REALTIME_DAILY_LIMIT?: string;
  BREEZE_CLIENT_TOKEN?: string;
  QUOTA: DurableObjectNamespace<QuotaTracker>;
}

type QuotaKind = "chat" | "realtime";

interface QuotaState {
  day: string;
  chat: number;
  realtime: number;
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

    let quota = await this.state.storage.get<QuotaState>("quota");
    if (!quota || quota.day !== day) {
      quota = { day, chat: 0, realtime: 0, seenChat: [] };
    }

    // Existing Durable Object state predates realtime quota tracking.
    quota.realtime ??= 0;

    const seen = quota.seenChat;
    const uniqueId = (requestId || "").trim();
    const alreadyCounted = uniqueId.length > 0 && seen.includes(uniqueId);
    const used = kind === "realtime" ? quota.realtime : quota.chat;
    const limit = intEnv(
      kind === "realtime" ? this.env.REALTIME_DAILY_LIMIT : this.env.CHAT_DAILY_LIMIT,
      kind === "realtime" ? 120 : 30,
    );

    if (!alreadyCounted) {
      if (used >= limit) {
        return Response.json({
          ok: false,
          kind,
          limit,
          used,
          remaining: 0,
          error: `Daily ${kind} limit reached.`,
        }, { status: 429 });
      }

      if (kind === "realtime") quota.realtime += 1;
      else quota.chat += 1;
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
      used: kind === "realtime" ? quota.realtime : quota.chat,
      remaining: Math.max(0, limit - (kind === "realtime" ? quota.realtime : quota.chat)),
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

  // Agent turns need enough reasoning to emit the OPEN:/SEARCH:/READ: action
  // lines Agent.swift parses; at "none" the model announces intent in prose
  // instead ("I'll look into...") and Agent.parse treats that as the final
  // answer. Verified against the real system prompt: none 7/9, low 8/9,
  // medium 9/9. Clients may request a cheaper effort for trivial chat; anything
  // unrecognized falls back to the configured default.
  //
  // Deliberately NOT `body.reasoning_effort`: shipped clients (<= 5.5.2) always
  // send "low" there, so honoring it would silently pin every existing install
  // to the 8/9 setting that breaks research. Only a client that opts in with
  // this field gets to choose.
  const allowedEfforts = new Set(["none", "low", "medium", "high"]);
  const requestedEffort = String(body.breeze_reasoning_effort ?? "").toLowerCase();
  const reasoningEffort = allowedEfforts.has(requestedEffort)
    ? requestedEffort
    : (env.AI_REASONING_EFFORT || "medium");

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
      reasoning_effort: reasoningEffort,
    }),
  });

  return withQuotaHeaders(upstream, quota);
}

async function proxyRealtimeToken(req: Request, env: Env) {
  let body: Record<string, unknown> = {};
  try {
    body = await req.json<Record<string, unknown>>();
  } catch {
    // Session instructions, tools, and voice are optional.
  }

  const { quotaResp, quota } = await checkQuota(req, env, "realtime");
  if (!quotaResp.ok) return json(quota, quotaResp.status);

  let providerKey: string;
  let providerModel: string;
  try {
    providerKey = requiredEnv(env.AI_PROVIDER_API_KEY || env.OPENAI_API_KEY, "AI_PROVIDER_API_KEY");
    providerModel = (env.AI_REALTIME_MODEL || "gpt-realtime-2.1-mini").trim();
  } catch {
    return json({ error: "provider_not_configured" }, 500);
  }

  const session: Record<string, unknown> = {
    type: "realtime",
    model: providerModel,
  };
  if (typeof body.instructions === "string" && body.instructions.trim()) {
    session.instructions = body.instructions.slice(0, 24000);
  }
  if (Array.isArray(body.tools)) session.tools = body.tools.slice(0, 32);
  const voice = typeof body.voice === "string" && body.voice.trim()
    ? body.voice.trim().slice(0, 32)
    : "marin";
  session.audio = { output: { voice } };

  const upstream = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${providerKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ session }),
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
    if (path === "/v1/realtime/token") return proxyRealtimeToken(req, env);
    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
