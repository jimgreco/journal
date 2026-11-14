import crypto from "node:crypto";
import appleSignin from "apple-signin-auth";
import { OAuth2Client } from "google-auth-library";
import { open, seal, sha256Hex, constantTimeEqualHex, parseKeyRing } from "./crypto.js";
import { ConflictError } from "./store.js";
import { weeklySummary, isMonday } from "./weekly.js";

const ACCESS_TTL_MS = 15 * 60_000;
const REFRESH_TTL_MS = 120 * 24 * 60 * 60_000;
const MAX_BODY_BYTES = 256 * 1024;
export const LIMITS = { textChars: 20_000, tags: 10, tagChars: 32, pageSize: 500 };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function loadConfig(env = process.env) {
  const production = env.NODE_ENV === "production";
  const list = (v) => String(v || "").split(",").map((s) => s.trim()).filter(Boolean);
  const config = {
    production,
    port: Number(env.PORT || 8791),
    databaseURL: env.DATABASE_URL || "",
    keys: parseKeyRing(env.JOURNAL_DATA_KEYS),
    sessionSecret: env.SESSION_SECRET || "",
    appleBundleId: env.APPLE_BUNDLE_ID || "",
    // The iOS app's Google OAuth client id(s), the identity-token audience.
    googleClientIds: list(env.GOOGLE_CLIENT_ID),
    allowedEmails: list(env.ALLOWED_EMAILS).map((e) => e.toLowerCase()),
    allowedAppleSubs: list(env.ALLOWED_APPLE_SUBS),
    weeklyTokenSha256: String(env.WEEKLY_SUMMARY_TOKEN_SHA256 || "").trim().toLowerCase(),
    weeklyEmail: String(env.WEEKLY_SUMMARY_EMAIL || "").trim(),
    trustProxyHops: Number(env.TRUST_PROXY_HOPS || 0),
    build: env.APP_BUILD || "dev",
    devSignIn: env.JOURNAL_DEV_SIGNIN === "1"
  };
  if (config.sessionSecret.length < 32) throw new Error("SESSION_SECRET must be at least 32 characters");
  if (production) {
    if (!config.databaseURL) throw new Error("DATABASE_URL is required in production");
    if (config.devSignIn) throw new Error("JOURNAL_DEV_SIGNIN is not allowed in production");
    if (!config.allowedEmails.length && !config.allowedAppleSubs.length) {
      throw new Error("ALLOWED_EMAILS or ALLOWED_APPLE_SUBS is required in production");
    }
  }
  return config;
}

// ---- small helpers -------------------------------------------------------

function b64url(buffer) {
  return Buffer.from(buffer).toString("base64url");
}

function send(response, status, body, headers = {}) {
  const payload = JSON.stringify(body);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
    ...headers
  });
  response.end(payload);
}

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function readJSON(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new HttpError(413, "body too large");
    chunks.push(chunk);
  }
  if (!size) return {};
  const type = String(request.headers["content-type"] || "");
  if (!type.startsWith("application/json")) throw new HttpError(415, "content-type must be application/json");
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value;
  } catch {
    throw new HttpError(400, "invalid JSON");
  }
}

function isDateKey(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

function isTimestamp(value) {
  return typeof value === "string" && value.length <= 40 && !Number.isNaN(Date.parse(value))
    && /^\d{4}-\d{2}-\d{2}T/.test(value);
}

export function validateEntry(body, now) {
  const errors = [];
  if (!isDateKey(body.entryDate)) errors.push("entryDate must be YYYY-MM-DD");
  if (!isTimestamp(body.createdAt)) errors.push("createdAt must be an ISO-8601 timestamp");
  if (!isTimestamp(body.updatedAt)) errors.push("updatedAt must be an ISO-8601 timestamp");
  if (body.source !== "text" && body.source !== "voice") errors.push("source must be text or voice");
  if (typeof body.private !== "boolean") errors.push("private must be a boolean");
  if (typeof body.text !== "string" || !body.text.trim()) errors.push("text is required");
  else if (body.text.length > LIMITS.textChars) errors.push(`text is limited to ${LIMITS.textChars} characters`);
  const mood = body.mood ?? null;
  if (mood !== null && !(Number.isInteger(mood) && mood >= 1 && mood <= 5)) errors.push("mood must be 1-5 or null");
  const tags = body.tags ?? [];
  if (!Array.isArray(tags) || tags.length > LIMITS.tags
    || !tags.every((t) => typeof t === "string" && t.trim() && t.length <= LIMITS.tagChars)) {
    errors.push(`tags must be up to ${LIMITS.tags} strings of at most ${LIMITS.tagChars} characters`);
  }
  if (errors.length) throw new HttpError(400, errors.join("; "));
  // A clock running ahead must not win every future edit.
  const clamp = (v) => new Date(Math.min(Date.parse(v), now.getTime())).toISOString();
  return {
    entryDate: body.entryDate,
    createdAt: clamp(body.createdAt),
    updatedAt: clamp(body.updatedAt),
    source: body.source,
    private: body.private,
    content: { text: body.text, mood, tags: [...new Set(tags.map((t) => t.trim()))] }
  };
}

export function decryptEntry(keys, row) {
  const base = {
    id: row.id,
    entryDate: row.entryDate,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    source: row.source,
    private: row.private,
    revision: row.revision
  };
  if (row.deletedAt) return { ...base, deleted: true, text: null, mood: null, tags: [] };
  const content = open(keys, row.userId, row.id, row);
  return { ...base, deleted: false, text: content.text, mood: content.mood ?? null, tags: content.tags ?? [] };
}

// ---- app -----------------------------------------------------------------

export function createApp({ store, config, verifyAppleToken, verifyGoogleToken, now = () => new Date() }) {
  const buckets = new Map();

  verifyAppleToken ??= async (identityToken) =>
    appleSignin.verifyIdToken(identityToken, { audience: config.appleBundleId, ignoreExpiration: false });

  const googleClient = new OAuth2Client();
  verifyGoogleToken ??= async (idToken) => {
    const ticket = await googleClient.verifyIdToken({ idToken, audience: config.googleClientIds });
    return ticket.getPayload();
  };

  function clientIP(request) {
    const socket = request.socket?.remoteAddress || "unknown";
    if (!config.trustProxyHops) return socket;
    const hops = String(request.headers["x-forwarded-for"] || "").split(",").map((s) => s.trim()).filter(Boolean);
    return hops[hops.length - config.trustProxyHops] || socket;
  }

  function limited(request, name, limit, windowMs) {
    const key = `${name}:${clientIP(request)}`;
    const t = now().getTime();
    let bucket = buckets.get(key);
    if (!bucket || bucket.resetAt <= t) {
      bucket = { count: 0, resetAt: t + windowMs };
      buckets.set(key, bucket);
    }
    bucket.count += 1;
    if (buckets.size > 10_000) {
      for (const [k, b] of buckets) if (b.resetAt <= t) buckets.delete(k);
    }
    return bucket.count > limit ? Math.ceil((bucket.resetAt - t) / 1000) : 0;
  }

  function sign(payload) {
    return b64url(crypto.createHmac("sha256", config.sessionSecret).update(payload).digest());
  }

  function accessToken(userId) {
    const payload = b64url(JSON.stringify({ v: 1, sub: userId, exp: now().getTime() + ACCESS_TTL_MS }));
    return `${payload}.${sign(payload)}`;
  }

  function verifyAccessToken(token) {
    const [payload, mac, extra] = String(token || "").split(".");
    if (!payload || !mac || extra !== undefined) return null;
    const expected = Buffer.from(sign(payload));
    const given = Buffer.from(mac);
    if (expected.length !== given.length || !crypto.timingSafeEqual(expected, given)) return null;
    try {
      const claims = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
      if (claims.v !== 1 || typeof claims.sub !== "string" || claims.exp <= now().getTime()) return null;
      return claims.sub;
    } catch {
      return null;
    }
  }

  async function issueSession(user) {
    const refreshToken = b64url(crypto.randomBytes(32));
    await store.createSession(user.id, sha256Hex(refreshToken), new Date(now().getTime() + REFRESH_TTL_MS));
    return {
      accessToken: accessToken(user.id),
      accessTokenExpiresIn: ACCESS_TTL_MS / 1000,
      refreshToken,
      user: { id: user.id, email: user.email }
    };
  }

  function isAllowed(provider, sub, email) {
    if (provider === "apple" && config.allowedAppleSubs.includes(sub)) return true;
    if (email && config.allowedEmails.includes(email.toLowerCase())) return true;
    return !config.production && !config.allowedEmails.length && !config.allowedAppleSubs.length;
  }

  // Shared by Apple and Google: only a verified email counts, and only allowed accounts get in.
  async function signInWith(response, provider, claims) {
    const subject = String(claims.sub).slice(0, 255);
    const verified = claims.email_verified === true || claims.email_verified === "true";
    const email = claims.email && verified ? String(claims.email) : "";
    if (!isAllowed(provider, subject, email)) {
      // The sub is the provider's opaque user id; for Apple the owner can copy it into ALLOWED_APPLE_SUBS.
      console.warn(`sign-in refused for ${provider} sub ${subject.slice(0, 64)}`);
      return send(response, 403, { error: "this journal is private" });
    }
    const user = await store.upsertUserByIdentity({
      provider,
      subject,
      email: email || `${subject}@${provider}.invalid`,
      emailVerified: Boolean(email)
    });
    return send(response, 200, await issueSession(user));
  }

  async function authenticate(request) {
    const match = String(request.headers.authorization || "").match(/^Bearer (.+)$/);
    const userId = match ? verifyAccessToken(match[1]) : null;
    const user = userId ? await store.getUser(userId) : null;
    if (!user) throw new HttpError(401, "sign in required");
    return user;
  }

  function hasWeeklyToken(request) {
    if (!/^[0-9a-f]{64}$/.test(config.weeklyTokenSha256) || !config.weeklyEmail) return false;
    const match = String(request.headers.authorization || "").match(/^Bearer (.+)$/);
    return Boolean(match) && constantTimeEqualHex(sha256Hex(match[1]), config.weeklyTokenSha256);
  }

  async function route(request, response) {
    const url = new URL(request.url, "http://journal.local");
    const path = url.pathname;
    const method = request.method;

    if (method === "GET" && path === "/health") {
      try {
        await store.health();
        return send(response, 200, { ok: true, status: "ok", db: true, build: config.build });
      } catch {
        return send(response, 503, { ok: false, status: "error", db: false, build: config.build });
      }
    }

    if (method === "GET" && path === "/api/weekly-summary") {
      const retry = limited(request, "weekly", 30, 15 * 60_000);
      if (retry) return send(response, 429, { error: "rate limited" }, { "retry-after": String(retry) });
      // Only the weekly-summary token is accepted here, never a user session.
      if (!hasWeeklyToken(request)) return send(response, 404, { error: "not found" });
      const week = url.searchParams.get("week");
      if (!isMonday(week)) return send(response, 400, { error: "week must be a Monday (YYYY-MM-DD)" });
      try {
        const data = await weeklySummary({ store, keys: config.keys, email: config.weeklyEmail, monday: week });
        const end = new Date(`${week}T00:00:00Z`);
        end.setUTCDate(end.getUTCDate() + 6);
        return send(response, 200, {
          version: 1,
          app: "journal",
          week: { start: week, end: end.toISOString().slice(0, 10) },
          generatedAt: now().toISOString(),
          data
        });
      } catch (error) {
        console.error("weekly-summary failed:", error.message);
        return send(response, 500, { error: "internal" });
      }
    }

    if (method === "POST" && path === "/auth/apple") {
      const retry = limited(request, "auth", 20, 15 * 60_000);
      if (retry) return send(response, 429, { error: "rate limited" }, { "retry-after": String(retry) });
      if (!config.appleBundleId) return send(response, 503, { error: "Apple sign-in is not configured" });
      const body = await readJSON(request);
      if (typeof body.identityToken !== "string" || body.identityToken.length > 8192) {
        throw new HttpError(400, "identityToken required");
      }
      let claims;
      try {
        claims = await verifyAppleToken(body.identityToken);
      } catch {
        claims = null;
      }
      if (!claims?.sub) return send(response, 401, { error: "invalid Apple token" });
      return signInWith(response, "apple", claims);
    }

    if (method === "POST" && path === "/auth/google") {
      const retry = limited(request, "auth", 20, 15 * 60_000);
      if (retry) return send(response, 429, { error: "rate limited" }, { "retry-after": String(retry) });
      if (!config.googleClientIds.length) return send(response, 503, { error: "Google sign-in is not configured" });
      const body = await readJSON(request);
      if (typeof body.idToken !== "string" || body.idToken.length > 8192) throw new HttpError(400, "idToken required");
      let claims;
      try {
        claims = await verifyGoogleToken(body.idToken);
      } catch {
        claims = null;
      }
      if (!claims?.sub) return send(response, 401, { error: "invalid Google token" });
      return signInWith(response, "google", claims);
    }

    if (method === "POST" && path === "/auth/dev") {
      if (config.production || !config.devSignIn) return send(response, 404, { error: "not found" });
      const body = await readJSON(request);
      const email = typeof body.email === "string" && body.email ? body.email : "dev@example.test";
      const user = await store.upsertUserByIdentity({ provider: "dev", subject: email, email, emailVerified: true });
      return send(response, 200, await issueSession(user));
    }

    if (method === "POST" && path === "/auth/refresh") {
      const retry = limited(request, "refresh", 60, 15 * 60_000);
      if (retry) return send(response, 429, { error: "rate limited" }, { "retry-after": String(retry) });
      const body = await readJSON(request);
      const session = typeof body.refreshToken === "string" && body.refreshToken.length <= 200
        ? await store.takeSession(sha256Hex(body.refreshToken))
        : null;
      const user = session ? await store.getUser(session.userId) : null;
      if (!user) return send(response, 401, { error: "invalid refresh token" });
      return send(response, 200, await issueSession(user));
    }

    if (method === "POST" && path === "/auth/signout") {
      const body = await readJSON(request);
      if (typeof body.refreshToken === "string" && body.refreshToken.length <= 200) {
        await store.takeSession(sha256Hex(body.refreshToken));
      }
      return send(response, 200, { ok: true });
    }

    if (!path.startsWith("/api/")) return send(response, 404, { error: "not found" });

    const retry = limited(request, "api", 600, 15 * 60_000);
    if (retry) return send(response, 429, { error: "rate limited" }, { "retry-after": String(retry) });
    const user = await authenticate(request);

    if (method === "GET" && path === "/api/me") {
      return send(response, 200, { id: user.id, email: user.email });
    }

    if (method === "GET" && path === "/api/entries") {
      const after = Number(url.searchParams.get("after") || 0);
      if (!Number.isSafeInteger(after) || after < 0) throw new HttpError(400, "after must be a revision number");
      const rows = await store.listEntriesAfter(user.id, after, LIMITS.pageSize + 1);
      const page = rows.slice(0, LIMITS.pageSize);
      return send(response, 200, {
        entries: page.map((row) => decryptEntry(config.keys, row)),
        revision: page.length ? page[page.length - 1].revision : after,
        more: rows.length > LIMITS.pageSize
      });
    }

    const entryMatch = path.match(/^\/api\/entries\/([^/]+)$/);
    if (entryMatch) {
      const id = entryMatch[1].toLowerCase();
      if (!UUID.test(id)) throw new HttpError(400, "entry id must be a UUID");
      if (method === "PUT") {
        const entry = validateEntry(await readJSON(request), now());
        const sealed = seal(config.keys, user.id, id, entry.content);
        const stored = await store.putEntry({
          id,
          userId: user.id,
          entryDate: entry.entryDate,
          createdAt: entry.createdAt,
          updatedAt: entry.updatedAt,
          source: entry.source,
          private: entry.private,
          ...sealed
        });
        return send(response, 200, decryptEntry(config.keys, stored));
      }
      if (method === "DELETE") {
        const stored = await store.deleteEntry(user.id, id, now().toISOString());
        return send(response, 200, decryptEntry(config.keys, stored));
      }
    }

    if (method === "GET" && path === "/api/export") {
      const entries = [];
      let after = 0;
      for (;;) {
        const rows = await store.listEntriesAfter(user.id, after, LIMITS.pageSize);
        if (!rows.length) break;
        for (const row of rows) if (!row.deletedAt) entries.push(decryptEntry(config.keys, row));
        after = rows[rows.length - 1].revision;
      }
      entries.sort((a, b) => a.entryDate.localeCompare(b.entryDate) || a.createdAt.localeCompare(b.createdAt));
      return send(response, 200, { exportedAt: now().toISOString(), entries }, {
        "content-disposition": "attachment; filename=\"journal-export.json\""
      });
    }

    if (method === "DELETE" && path === "/api/account") {
      await store.deleteUser(user.id);
      return send(response, 200, { ok: true });
    }

    return send(response, 404, { error: "not found" });
  }

  return async function handler(request, response) {
    try {
      await route(request, response);
    } catch (error) {
      if (error instanceof HttpError) return send(response, error.status, { error: error.message });
      if (error instanceof ConflictError) return send(response, 409, { error: "conflict" });
      console.error("request failed:", error.message);
      if (!response.headersSent) send(response, 500, { error: "internal" });
    }
  };
}
