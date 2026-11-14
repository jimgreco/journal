import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import http from "node:http";
import pg from "pg";
import { createApp, loadConfig } from "../src/app.js";
import { MemoryStore, PostgresStore } from "../src/store.js";
import { migrate } from "../src/migrate.js";
import { sha256Hex } from "../src/crypto.js";

const KEY = crypto.randomBytes(32).toString("base64");
const WEEKLY_TOKEN = "weekly-test-token";
const OWNER = "owner@example.com";

function baseEnv(extra = {}) {
  return {
    JOURNAL_DATA_KEYS: `1:${KEY}`,
    SESSION_SECRET: "x".repeat(40),
    APPLE_BUNDLE_ID: "com.jimgreco.journal",
    GOOGLE_CLIENT_ID: "test.apps.googleusercontent.com",
    ALLOWED_EMAILS: OWNER,
    WEEKLY_SUMMARY_TOKEN_SHA256: sha256Hex(WEEKLY_TOKEN),
    WEEKLY_SUMMARY_EMAIL: OWNER,
    ...extra
  };
}

// Fake Apple verifier: the "identity token" is a JSON string of the claims.
async function fakeApple(token) {
  const claims = JSON.parse(token);
  if (claims.invalid) throw new Error("bad signature");
  return claims;
}
const fakeGoogle = fakeApple;

async function startServer(store, env = baseEnv(), now) {
  const config = loadConfig(env);
  const server = http.createServer(createApp({ store, config, verifyAppleToken: fakeApple, verifyGoogleToken: fakeGoogle, now }));
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = async (method, path, { body, token } = {}) => {
    const response = await fetch(base + path, {
      method,
      headers: {
        ...(body ? { "content-type": "application/json" } : {}),
        ...(token ? { authorization: `Bearer ${token}` } : {})
      },
      body: body ? JSON.stringify(body) : undefined
    });
    const text = await response.text();
    return { status: response.status, headers: response.headers, body: text ? JSON.parse(text) : null };
  };
  return { server, call, close: () => new Promise((r) => server.close(r)) };
}

function entry(overrides = {}) {
  return {
    entryDate: "2026-11-04",
    createdAt: "2026-11-04T21:15:00.000Z",
    updatedAt: "2026-11-04T21:15:00.000Z",
    source: "text",
    private: false,
    text: "Felt good after the long run. Work stress is lower this week.",
    mood: 4,
    tags: ["running", "work"],
    ...overrides
  };
}

const stores = [["memory", async () => ({ store: new MemoryStore(), cleanup: async () => {} })]];
const pgURL = process.env.JOURNAL_TEST_DATABASE_URL;
if (pgURL) {
  stores.push(["postgres", async () => {
    const admin = new pg.Client({ connectionString: pgURL });
    await admin.connect();
    await admin.query(`DROP TABLE IF EXISTS journal_entries, journal_sessions, journal_identities, journal_users, app_schema_versions CASCADE;
      DROP SEQUENCE IF EXISTS journal_entry_revision;`);
    await admin.end();
    await migrate(pgURL);
    assert.deepEqual(await migrate(pgURL), [], "migrations are idempotent");
    const store = new PostgresStore(pgURL);
    return { store, cleanup: () => store.close(), url: pgURL };
  }]);
}

for (const [name, makeStore] of stores) {
  describe(`journal API (${name} store)`, () => {
    let ctx;
    let api;
    let token;
    let refresh;

    before(async () => {
      ctx = await makeStore();
      api = await startServer(ctx.store);
      const signIn = await api.call("POST", "/auth/apple", {
        body: { identityToken: JSON.stringify({ sub: "apple-owner", email: OWNER, email_verified: "true" }) }
      });
      assert.equal(signIn.status, 200);
      token = signIn.body.accessToken;
      refresh = signIn.body.refreshToken;
    });

    after(async () => {
      await api.close();
      await ctx.cleanup();
    });

    test("health reports the database", async () => {
      const res = await api.call("GET", "/health");
      assert.equal(res.status, 200);
      assert.equal(res.body.ok, true);
      assert.equal(res.body.db, true);
    });

    test("only allowed Apple accounts can sign in", async () => {
      const stranger = await api.call("POST", "/auth/apple", {
        body: { identityToken: JSON.stringify({ sub: "apple-x", email: "someone@else.com", email_verified: true }) }
      });
      assert.equal(stranger.status, 403);
      const unverified = await api.call("POST", "/auth/apple", {
        body: { identityToken: JSON.stringify({ sub: "apple-y", email: OWNER, email_verified: false }) }
      });
      assert.equal(unverified.status, 403);
      const forged = await api.call("POST", "/auth/apple", {
        body: { identityToken: JSON.stringify({ invalid: true }) }
      });
      assert.equal(forged.status, 401);
    });

    test("Google sign-in reaches the same journal as Apple via the verified email", async () => {
      const id = crypto.randomUUID();
      await api.call("PUT", `/api/entries/${id}`, { token, body: entry({ text: "written after Apple sign-in" }) });
      const google = await api.call("POST", "/auth/google", {
        body: { idToken: JSON.stringify({ sub: "google-owner", email: OWNER.toUpperCase(), email_verified: true }) }
      });
      assert.equal(google.status, 200);
      const list = await api.call("GET", "/api/entries", { token: google.body.accessToken });
      assert.ok(list.body.entries.some((e) => e.id === id), "same account, same entries");
      const again = await api.call("POST", "/auth/google", {
        body: { idToken: JSON.stringify({ sub: "google-owner", email: OWNER, email_verified: true }) }
      });
      assert.equal(again.body.user.id, google.body.user.id);
      const stranger = await api.call("POST", "/auth/google", {
        body: { idToken: JSON.stringify({ sub: "google-x", email: "someone@else.com", email_verified: true }) }
      });
      assert.equal(stranger.status, 403);
      const unverified = await api.call("POST", "/auth/google", {
        body: { idToken: JSON.stringify({ sub: "google-y", email: OWNER, email_verified: false }) }
      });
      assert.equal(unverified.status, 403, "an unverified email is neither allowed nor linked");
      const forged = await api.call("POST", "/auth/google", { body: { idToken: JSON.stringify({ invalid: true }) } });
      assert.equal(forged.status, 401);
    });

    test("API requires a valid access token", async () => {
      assert.equal((await api.call("GET", "/api/entries")).status, 401);
      assert.equal((await api.call("GET", "/api/entries", { token: "abc.def" })).status, 401);
      assert.equal((await api.call("GET", "/api/entries", { token: token + "x" })).status, 401);
      assert.equal((await api.call("GET", "/api/entries", { token: WEEKLY_TOKEN })).status, 401);
    });

    test("refresh tokens rotate and cannot be reused", async () => {
      const first = await api.call("POST", "/auth/refresh", { body: { refreshToken: refresh } });
      assert.equal(first.status, 200);
      assert.notEqual(first.body.refreshToken, refresh);
      const reuse = await api.call("POST", "/auth/refresh", { body: { refreshToken: refresh } });
      assert.equal(reuse.status, 401);
      refresh = first.body.refreshToken;
      token = first.body.accessToken;
    });

    test("entries round-trip and are encrypted at rest", async () => {
      const id = crypto.randomUUID();
      const put = await api.call("PUT", `/api/entries/${id}`, { token, body: entry() });
      assert.equal(put.status, 200);
      assert.equal(put.body.text, entry().text);
      assert.deepEqual(put.body.tags, ["running", "work"]);

      if (ctx.url) {
        const client = new pg.Client({ connectionString: ctx.url });
        await client.connect();
        const { rows } = await client.query("SELECT * FROM journal_entries WHERE id = $1", [id]);
        await client.end();
        const raw = JSON.stringify(rows[0]) + rows[0].ciphertext.toString("utf8");
        assert.ok(!raw.includes("long run"), "plaintext must not reach the database");
        assert.ok(!raw.includes("running"));
      } else {
        const raw = ctx.store.entries.get(id).ciphertext.toString("utf8");
        assert.ok(!raw.includes("long run"));
      }

      const list = await api.call("GET", "/api/entries", { token });
      assert.ok(list.body.entries.some((e) => e.id === id && e.text === entry().text));
    });

    test("validation rejects bad entries", async () => {
      const id = crypto.randomUUID();
      for (const bad of [
        { text: "" },
        { text: "x".repeat(20_001) },
        { entryDate: "2026-02-30" },
        { source: "audio" },
        { private: "no" },
        { mood: 9 },
        { tags: ["x".repeat(40)] }
      ]) {
        const res = await api.call("PUT", `/api/entries/${id}`, { token, body: entry(bad) });
        assert.equal(res.status, 400, JSON.stringify(bad));
      }
      assert.equal((await api.call("PUT", "/api/entries/not-a-uuid", { token, body: entry() })).status, 400);
    });

    test("last write wins and older edits are ignored", async () => {
      const id = crypto.randomUUID();
      await api.call("PUT", `/api/entries/${id}`, { token, body: entry({ text: "v1" }) });
      await api.call("PUT", `/api/entries/${id}`, {
        token, body: entry({ text: "v2", updatedAt: "2026-11-04T22:00:00.000Z" })
      });
      const stale = await api.call("PUT", `/api/entries/${id}`, {
        token, body: entry({ text: "stale", updatedAt: "2026-11-04T21:30:00.000Z" })
      });
      assert.equal(stale.body.text, "v2");
    });

    test("delete wipes content and syncs a tombstone", async () => {
      const id = crypto.randomUUID();
      const created = await api.call("PUT", `/api/entries/${id}`, { token, body: entry({ text: "to delete" }) });
      const del = await api.call("DELETE", `/api/entries/${id}`, { token });
      assert.equal(del.status, 200);
      assert.equal(del.body.deleted, true);
      assert.equal(del.body.text, null);
      const resurrect = await api.call("PUT", `/api/entries/${id}`, {
        token, body: entry({ text: "back", updatedAt: new Date().toISOString() })
      });
      assert.equal(resurrect.body.deleted, true, "a deleted entry stays deleted");
      const changes = await api.call("GET", `/api/entries?after=${created.body.revision}`, { token });
      assert.ok(changes.body.entries.some((e) => e.id === id && e.deleted));
    });

    test("another user cannot touch someone else's entry", async () => {
      const id = crypto.randomUUID();
      await api.call("PUT", `/api/entries/${id}`, { token, body: entry() });
      const other = await startServer(ctx.store, baseEnv({ ALLOWED_EMAILS: `${OWNER},other@example.com` }));
      try {
        const signIn = await other.call("POST", "/auth/apple", {
          body: { identityToken: JSON.stringify({ sub: "apple-other", email: "other@example.com", email_verified: true }) }
        });
        const otherToken = signIn.body.accessToken;
        assert.equal((await other.call("PUT", `/api/entries/${id}`, { token: otherToken, body: entry() })).status, 409);
        assert.equal((await other.call("DELETE", `/api/entries/${id}`, { token: otherToken })).status, 409);
        const list = await other.call("GET", "/api/entries", { token: otherToken });
        assert.equal(list.body.entries.length, 0);
      } finally {
        await other.close();
      }
    });

    test("weekly summary hides private entries and needs its own token", async () => {
      const week = "2026-11-09";
      await api.call("PUT", `/api/entries/${crypto.randomUUID()}`, {
        token, body: entry({ entryDate: "2026-11-10", text: "Shared thought about training", source: "voice", mood: 3 })
      });
      await api.call("PUT", `/api/entries/${crypto.randomUUID()}`, {
        token, body: entry({ entryDate: "2026-11-11", text: "SECRET private note", private: true })
      });
      await api.call("PUT", `/api/entries/${crypto.randomUUID()}`, {
        token, body: entry({ entryDate: "2026-11-17", text: "next week, out of range" })
      });

      assert.equal((await api.call("GET", `/api/weekly-summary?week=${week}`)).status, 404);
      assert.equal((await api.call("GET", `/api/weekly-summary?week=${week}`, { token })).status, 404,
        "user sessions are not accepted on the weekly route");
      assert.equal((await api.call("GET", "/api/weekly-summary?week=2026-11-10", { token: WEEKLY_TOKEN })).status, 400);

      const res = await api.call("GET", `/api/weekly-summary?week=${week}`, { token: WEEKLY_TOKEN });
      assert.equal(res.status, 200);
      assert.equal(res.headers.get("cache-control"), "no-store");
      assert.equal(res.body.app, "journal");
      assert.deepEqual(res.body.week, { start: "2026-11-09", end: "2026-11-15" });
      const { data } = res.body;
      assert.equal(data.status, "ok");
      assert.equal(data.current.entries, 2);
      assert.equal(data.current.privateEntries, 1);
      assert.equal(data.current.voiceEntries, 1);
      assert.equal(data.entries.length, 1);
      assert.equal(data.entries[0].text, "Shared thought about training");
      assert.equal(data.entries[0].weekday, "Tue");
      assert.ok(!JSON.stringify(res.body).includes("SECRET"));
      assert.ok(data.previous.entries >= 1, "previous week counts last week's entries");
    });

    test("export returns live entries, account delete removes everything", async () => {
      const exported = await api.call("GET", "/api/export", { token });
      assert.equal(exported.status, 200);
      assert.ok(exported.body.entries.length > 0);
      assert.ok(exported.body.entries.every((e) => !e.deleted));
      const del = await api.call("DELETE", "/api/account", { token });
      assert.equal(del.status, 200);
      assert.equal((await api.call("GET", "/api/entries", { token })).status, 401);
      const weekly = await api.call("GET", "/api/weekly-summary?week=2026-11-09", { token: WEEKLY_TOKEN });
      assert.deepEqual(weekly.body.data, { status: "no-account" });
    });
  });
}

describe("configuration", () => {
  test("weekly route is a 404 when unconfigured", async () => {
    const api = await startServer(new MemoryStore(), baseEnv({ WEEKLY_SUMMARY_TOKEN_SHA256: "" }));
    try {
      const res = await api.call("GET", "/api/weekly-summary?week=2026-11-09", { token: WEEKLY_TOKEN });
      assert.equal(res.status, 404);
    } finally {
      await api.close();
    }
  });

  test("Google sign-in is off until a client id is set", async () => {
    const api = await startServer(new MemoryStore(), baseEnv({ GOOGLE_CLIENT_ID: "" }));
    try {
      const res = await api.call("POST", "/auth/google", { body: { idToken: "{}" } });
      assert.equal(res.status, 503);
    } finally {
      await api.close();
    }
  });

  test("production refuses unsafe settings", () => {
    const prod = baseEnv({ NODE_ENV: "production", DATABASE_URL: "postgres://x" });
    assert.doesNotThrow(() => loadConfig(prod));
    assert.throws(() => loadConfig({ ...prod, JOURNAL_DEV_SIGNIN: "1" }));
    assert.throws(() => loadConfig({ ...prod, ALLOWED_EMAILS: "" }));
    assert.throws(() => loadConfig({ ...prod, DATABASE_URL: "" }));
    assert.throws(() => loadConfig({ ...prod, SESSION_SECRET: "short" }));
    assert.throws(() => loadConfig({ ...prod, JOURNAL_DATA_KEYS: "1:c2hvcnQ=" }));
  });

  test("dev sign-in only works when enabled outside production", async () => {
    const off = await startServer(new MemoryStore());
    const on = await startServer(new MemoryStore(), baseEnv({ JOURNAL_DEV_SIGNIN: "1" }));
    try {
      assert.equal((await off.call("POST", "/auth/dev", { body: {} })).status, 404);
      assert.equal((await on.call("POST", "/auth/dev", { body: {} })).status, 200);
    } finally {
      await off.close();
      await on.close();
    }
  });

  test("auth is rate limited", async () => {
    const api = await startServer(new MemoryStore());
    try {
      let last;
      for (let i = 0; i < 21; i += 1) {
        last = await api.call("POST", "/auth/apple", { body: { identityToken: JSON.stringify({ invalid: true }) } });
      }
      assert.equal(last.status, 429);
    } finally {
      await api.close();
    }
  });
});
