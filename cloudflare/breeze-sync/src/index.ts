import { createRemoteJWKSet, jwtVerify } from "jose";
import { DurableObject } from "cloudflare:workers";

export interface Env {
  JWT_ISSUER?: string;
  JWT_AUDIENCE?: string;
  JWT_JWKS_URL?: string;
  ALLOWED_ORIGINS?: string;
  SYNC: DurableObjectNamespace<SyncAccount>;
}

export type Collection = "bookmarks" | "history" | "chats";
export interface EncryptedEnvelope {
  recordId: string;
  collection: Collection;
  operationId: string;
  deviceId: string;
  keyEpoch: number;
  nonce: string;
  ciphertext: string;
  deleted: boolean;
  expectedRevision: number;
}
interface LogEntry { cursor: number; envelope: EncryptedEnvelope; payloadHash: string; revision: number; }
interface RecordHead { cursor: number; revision: number; envelope: EncryptedEnvelope; }
interface Device { deviceId: string; name: string; registeredAt: string; revokedAt?: string; }
interface Meta { cursor: number; }
interface OperationIndex { cursor: number; payloadHash: string; }

const MAX_BATCH = 100;
const MAX_OPERATION_BYTES = 64 * 1024;
const MAX_BATCH_BYTES = 512 * 1024;
const MAX_PAGE = 100;
const jwksByUrl = new Map<string, ReturnType<typeof createRemoteJWKSet>>();

function positiveInt(value: string | null, fallback: number, max: number): number {
  const n = Number(value);
  return Number.isSafeInteger(n) && n >= 0 && n <= max ? n : fallback;
}

function originHeaders(request: Request, env: Env): Headers {
  const headers = new Headers({ "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" });
  const origin = request.headers.get("Origin");
  const allowed = (env.ALLOWED_ORIGINS ?? "").split(",").map((item) => item.trim()).filter(Boolean);
  if (origin && allowed.includes(origin)) {
    headers.set("Access-Control-Allow-Origin", origin);
    headers.set("Vary", "Origin");
  }
  return headers;
}

function json(request: Request, env: Env, data: unknown, status = 200): Response {
  return Response.json(data, { status, headers: originHeaders(request, env) });
}

async function accountSubject(request: Request, env: Env): Promise<string | null> {
  if (!env.JWT_ISSUER || !env.JWT_AUDIENCE || !env.JWT_JWKS_URL) return null;
  const token = request.headers.get("Authorization")?.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!token) return null;
  try {
    const url = new URL(env.JWT_JWKS_URL);
    if (url.protocol !== "https:") return null;
    let jwks = jwksByUrl.get(url.href);
    if (!jwks) {
      jwks = createRemoteJWKSet(url);
      jwksByUrl.set(url.href, jwks);
    }
    const { payload } = await jwtVerify(token, jwks, {
      issuer: env.JWT_ISSUER,
      audience: env.JWT_AUDIENCE,
      algorithms: ["RS256", "PS256", "ES256"],
      clockTolerance: 5,
      maxTokenAge: "24h",
      requiredClaims: ["exp", "iat", "sub"],
    });
    return typeof payload.sub === "string" && payload.sub.length > 0 ? payload.sub : null;
  } catch {
    return null;
  }
}

async function accountName(subject: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(subject));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function isId(value: unknown): value is string {
  return typeof value === "string" && /^[\w-]{1,128}$/.test(value);
}

function isEnvelope(value: unknown): value is EncryptedEnvelope {
  if (!value || typeof value !== "object") return false;
  const v = value as Partial<EncryptedEnvelope>;
  const expected = ["recordId", "collection", "operationId", "deviceId", "keyEpoch", "nonce", "ciphertext", "deleted", "expectedRevision"];
  if (Object.keys(value).length !== expected.length || !expected.every((key) => Object.hasOwn(value, key))) return false;
  return isId(v.recordId) && isId(v.operationId) && isId(v.deviceId)
    && (v.collection === "bookmarks" || v.collection === "history" || v.collection === "chats")
    && Number.isSafeInteger(v.keyEpoch) && (v.keyEpoch ?? 0) >= 0
    && typeof v.nonce === "string" && /^[A-Za-z0-9_-]{12,64}$/.test(v.nonce)
    && typeof v.ciphertext === "string" && /^[A-Za-z0-9_-]+$/.test(v.ciphertext)
    && typeof v.deleted === "boolean"
    && Number.isSafeInteger(v.expectedRevision) && (v.expectedRevision ?? -1) >= 0;
}

function canonicalEnvelope(envelope: EncryptedEnvelope): string {
  return JSON.stringify({
    recordId: envelope.recordId,
    collection: envelope.collection,
    operationId: envelope.operationId,
    deviceId: envelope.deviceId,
    keyEpoch: envelope.keyEpoch,
    nonce: envelope.nonce,
    ciphertext: envelope.ciphertext,
    deleted: envelope.deleted,
    expectedRevision: envelope.expectedRevision,
  });
}

async function payloadHash(envelope: EncryptedEnvelope): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonicalEnvelope(envelope)));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function operationSize(envelope: EncryptedEnvelope): number {
  return new TextEncoder().encode(canonicalEnvelope(envelope)).byteLength;
}

export class SyncAccount extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/devices") return this.registerDevice(request);
    if (request.method === "DELETE" && url.pathname.startsWith("/devices/")) return this.revokeDevice(decodeURIComponent(url.pathname.slice("/devices/".length)));
    if (request.method === "POST" && url.pathname === "/sync/push") return this.push(request);
    if (request.method === "GET" && url.pathname === "/sync/pull") return this.pull(url);
    if (request.method === "GET" && url.pathname === "/devices") return this.listDevices();
    return Response.json({ error: "not_found" }, { status: 404 });
  }

  private async registerDevice(request: Request): Promise<Response> {
    const body = await request.json<{ deviceId?: unknown; name?: unknown }>();
    if (!isId(body.deviceId) || (body.name !== undefined && (typeof body.name !== "string" || body.name.length > 80))) {
      return Response.json({ error: "invalid_device" }, { status: 400 });
    }
    const deviceId = body.deviceId;
    const key = `device:${deviceId}`;
    return this.ctx.storage.transaction(async (txn) => {
      const previous = await txn.get<Device>(key);
      if (previous && !previous.revokedAt) return Response.json({ device: previous, created: false });
      const device: Device = { deviceId, name: typeof body.name === "string" ? body.name : "Device", registeredAt: new Date().toISOString() };
      await txn.put(key, device);
      return Response.json({ device, created: true });
    });
  }

  private async revokeDevice(deviceId: string): Promise<Response> {
    let decodedId: string;
    try { decodedId = decodeURIComponent(deviceId); } catch { return Response.json({ error: "invalid_device" }, { status: 400 }); }
    if (!isId(decodedId)) return Response.json({ error: "invalid_device" }, { status: 400 });
    return this.ctx.storage.transaction(async (txn) => {
      const device = await txn.get<Device>(`device:${decodedId}`);
      if (!device) return Response.json({ error: "device_not_found" }, { status: 404 });
      device.revokedAt = new Date().toISOString();
      await txn.put(`device:${decodedId}`, device);
      return Response.json({ deviceId: decodedId, revoked: true });
    });
  }

  private async listDevices(): Promise<Response> {
    const devices = await this.ctx.storage.list<Device>({ prefix: "device:" });
    return Response.json({ devices: Array.from(devices.values()) });
  }

  private async push(request: Request): Promise<Response> {
    const announcedLength = Number(request.headers.get("Content-Length") ?? "0");
    if (announcedLength > MAX_BATCH_BYTES + 64 * 1024) return Response.json({ error: "batch_too_large" }, { status: 413 });
    let body: unknown;
    try {
      const raw = await request.text();
      if (new TextEncoder().encode(raw).byteLength > MAX_BATCH_BYTES + 64 * 1024) return Response.json({ error: "batch_too_large" }, { status: 413 });
      body = JSON.parse(raw);
    } catch {
      return Response.json({ error: "invalid_json" }, { status: 400 });
    }
    if (!body || typeof body !== "object" || !Array.isArray((body as { operations?: unknown }).operations)) return Response.json({ error: "invalid_request" }, { status: 400 });
    const operations = (body as { operations: unknown[] }).operations;
    if (operations.length === 0 || operations.length > MAX_BATCH || !operations.every(isEnvelope)) return Response.json({ error: "invalid_operations" }, { status: 400 });
    let byteTotal = 0;
    for (const operation of operations) {
      const bytes = operationSize(operation);
      if (bytes > MAX_OPERATION_BYTES) return Response.json({ error: "operation_too_large" }, { status: 413 });
      byteTotal += bytes;
      if (byteTotal > MAX_BATCH_BYTES) return Response.json({ error: "batch_too_large" }, { status: 413 });
    }
    if (new Set(operations.map((operation) => operation.operationId)).size !== operations.length) return Response.json({ error: "duplicate_operation_id_in_batch" }, { status: 400 });
    const recordKeys = operations.map((operation) => `${operation.collection}:${operation.recordId}`);
    if (new Set(recordKeys).size !== operations.length) return Response.json({ error: "duplicate_record_in_batch" }, { status: 400 });
    if (new Set(operations.map((operation) => operation.deviceId)).size !== 1) return Response.json({ error: "mixed_devices_in_batch" }, { status: 400 });
    const deviceId = operations[0].deviceId;
    const hashes = await Promise.all(operations.map(payloadHash));
    return this.ctx.storage.transaction(async (txn) => {
      const device = await txn.get<Device>(`device:${deviceId}`);
      if (!device || device.revokedAt) return Response.json({ error: "device_not_enrolled" }, { status: 403 });
      let meta = await txn.get<Meta>("meta");
      if (!meta) meta = { cursor: 0 };
      const conflicts: Array<{ recordId: string; collection: Collection; expectedRevision: number; currentRevision: number; current: EncryptedEnvelope | null }> = [];
      const simulatedHeads = new Map<string, RecordHead | null>();
      const existing: Array<{ operationId: string; cursor: number }> = [];
      for (let index = 0; index < operations.length; index++) {
        const operation = operations[index];
        const idKey = `operation:${operation.operationId}`;
        const indexed = await txn.get<OperationIndex>(idKey);
        if (indexed) {
          if (indexed.payloadHash !== hashes[index]) return Response.json({ error: "operation_id_reused", operationId: operation.operationId }, { status: 409 });
          existing.push({ operationId: operation.operationId, cursor: indexed.cursor });
          continue;
        }
        const recordKey = `record:${operation.collection}:${operation.recordId}`;
        if (!simulatedHeads.has(recordKey)) simulatedHeads.set(recordKey, await txn.get<RecordHead>(recordKey) ?? null);
        const current = simulatedHeads.get(recordKey) ?? null;
        const revision = current?.revision ?? 0;
        if (operation.expectedRevision !== revision) {
          conflicts.push({ recordId: operation.recordId, collection: operation.collection, expectedRevision: operation.expectedRevision, currentRevision: revision, current: current?.envelope ?? null });
        } else {
          simulatedHeads.set(recordKey, { cursor: meta.cursor + index + 1, revision: revision + 1, envelope: operation });
        }
      }
      if (conflicts.length) return Response.json({ error: "revision_conflict", conflicts }, { status: 409 });
      if (existing.length) {
        if (existing.length !== operations.length) return Response.json({ error: "partially_replayed_batch", duplicateOperations: existing }, { status: 409 });
        return Response.json({ accepted: operations.length, duplicate: true, operations: existing, cursor: meta.cursor });
      }
      const committed: Array<{ operationId: string; cursor: number; revision: number }> = [];
      for (let index = 0; index < operations.length; index++) {
        const envelope = operations[index];
        meta.cursor += 1;
        const entry: LogEntry = { cursor: meta.cursor, envelope, payloadHash: hashes[index], revision: envelope.expectedRevision + 1 };
        await txn.put(`log:${String(entry.cursor).padStart(16, "0")}`, entry);
        await txn.put(`operation:${envelope.operationId}`, { cursor: entry.cursor, payloadHash: hashes[index] } satisfies OperationIndex);
        await txn.put(`record:${envelope.collection}:${envelope.recordId}`, { cursor: entry.cursor, revision: entry.revision, envelope } satisfies RecordHead);
        committed.push({ operationId: envelope.operationId, cursor: entry.cursor, revision: entry.revision });
      }
      await txn.put("meta", meta);
      return Response.json({ accepted: committed.length, duplicate: false, operations: committed, cursor: meta.cursor });
    });
  }

  private async pull(url: URL): Promise<Response> {
    const deviceId = url.searchParams.get("deviceId");
    if (!isId(deviceId)) return Response.json({ error: "invalid_device" }, { status: 400 });
    const cursorText = url.searchParams.get("cursor");
    const cursor = Number(cursorText ?? "0");
    const limitText = url.searchParams.get("limit");
    const limit = positiveInt(limitText, MAX_PAGE, MAX_PAGE);
    if (!Number.isSafeInteger(cursor) || cursor < 0 || (cursorText !== null && String(cursor) !== cursorText) || limit < 1) return Response.json({ error: "invalid_cursor_or_limit" }, { status: 400 });
    return this.ctx.storage.transaction(async (txn) => {
      const device = await txn.get<Device>(`device:${deviceId}`);
      if (!device || device.revokedAt) return Response.json({ error: "device_not_enrolled" }, { status: 403 });
      const meta = await txn.get<Meta>("meta") ?? { cursor: 0 };
      const end = Math.min(meta.cursor, cursor + limit);
      const keys = Array.from({ length: Math.max(0, end - cursor) }, (_, index) => `log:${String(cursor + index + 1).padStart(16, "0")}`);
      const stored = await txn.get<LogEntry>(keys);
      const entries = keys.flatMap((key) => {
        const entry = stored.get(key);
        return entry ? [{ cursor: entry.cursor, revision: entry.revision, envelope: entry.envelope }] : [];
      });
      const nextCursor = entries.length ? entries[entries.length - 1].cursor : cursor;
      return Response.json({ entries, cursor: nextCursor, hasMore: nextCursor < meta.cursor });
    });
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") {
      const headers = originHeaders(request, env);
      headers.set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
      headers.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
      headers.set("Access-Control-Max-Age", "600");
      return new Response(null, { status: 204, headers });
    }
    if (request.method === "GET" && url.pathname === "/health") return json(request, env, { ok: true, service: "breeze-sync" });
    const subject = await accountSubject(request, env);
    if (!subject) return json(request, env, { error: "unauthorized" }, 401);
    const account = env.SYNC.idFromName(await accountName(subject));
    const path = url.pathname === "/v1/devices" ? "/devices"
      : url.pathname.startsWith("/v1/devices/") ? url.pathname.slice("/v1".length)
        : url.pathname.startsWith("/v1/sync/") ? url.pathname.slice("/v1".length) : "";
    if (!path) return json(request, env, { error: "not_found" }, 404);
    const proxied = await env.SYNC.get(account).fetch(`https://sync.internal${path}${url.search}`, request);
    const headers = new Headers(proxied.headers);
    const allowedOrigins = (env.ALLOWED_ORIGINS ?? "").split(",").map((item) => item.trim()).filter(Boolean);
    const origin = request.headers.get("Origin");
    if (origin && allowedOrigins.includes(origin)) {
      headers.set("Access-Control-Allow-Origin", origin);
      headers.set("Vary", "Origin");
    }
    headers.set("Cache-Control", "no-store");
    headers.set("X-Content-Type-Options", "nosniff");
    return new Response(proxied.body, { status: proxied.status, statusText: proxied.statusText, headers });
  },
};
