import crypto from "node:crypto";
import pg from "pg";

// Two stores with the same contract: MemoryStore for tests and local
// development, PostgresStore for production. Rows hold ciphertext only; the
// app layer encrypts and decrypts.
//
// Entry row: { id, userId, entryDate, createdAt, updatedAt, source, private,
//              keyId, nonce, ciphertext, deletedAt, revision }

export class ConflictError extends Error {}

function newer(incoming, existing) {
  return new Date(incoming.updatedAt).getTime() >= new Date(existing.updatedAt).getTime();
}

export class MemoryStore {
  constructor() {
    this.users = new Map();
    this.sessions = new Map();
    this.entries = new Map();
    this.revision = 0;
  }

  async upsertUserByApple({ appleSub, email }) {
    for (const user of this.users.values()) {
      if (user.appleSub === appleSub) {
        user.email = email;
        return { ...user };
      }
    }
    const user = { id: crypto.randomUUID(), appleSub, email, createdAt: new Date().toISOString() };
    this.users.set(user.id, user);
    return { ...user };
  }

  async getUser(id) {
    const user = this.users.get(id);
    return user ? { ...user } : null;
  }

  async findUserByEmail(email) {
    const wanted = String(email).toLowerCase();
    for (const user of this.users.values()) if (user.email.toLowerCase() === wanted) return { ...user };
    return null;
  }

  async createSession(userId, tokenHash, expiresAt) {
    this.sessions.set(tokenHash, { userId, expiresAt: new Date(expiresAt) });
  }

  async takeSession(tokenHash) {
    const session = this.sessions.get(tokenHash);
    this.sessions.delete(tokenHash);
    if (!session || session.expiresAt <= new Date()) return null;
    return { userId: session.userId };
  }

  async deleteSessionsForUser(userId) {
    for (const [hash, session] of this.sessions) if (session.userId === userId) this.sessions.delete(hash);
  }

  async putEntry(row) {
    const existing = this.entries.get(row.id);
    if (existing && existing.userId !== row.userId) throw new ConflictError("entry id belongs to another user");
    if (existing && (existing.deletedAt || !newer(row, existing))) return { ...existing };
    const stored = {
      ...row,
      createdAt: existing?.createdAt ?? row.createdAt,
      deletedAt: null,
      revision: ++this.revision
    };
    this.entries.set(row.id, stored);
    return { ...stored };
  }

  async deleteEntry(userId, id, deletedAt) {
    const existing = this.entries.get(id);
    if (existing && existing.userId !== userId) throw new ConflictError("entry id belongs to another user");
    if (existing?.deletedAt) return { ...existing };
    const tombstone = {
      id,
      userId,
      entryDate: existing?.entryDate ?? deletedAt.slice(0, 10),
      createdAt: existing?.createdAt ?? deletedAt,
      updatedAt: deletedAt,
      source: existing?.source ?? "text",
      private: existing?.private ?? false,
      keyId: null,
      nonce: null,
      ciphertext: null,
      deletedAt,
      revision: ++this.revision
    };
    this.entries.set(id, tombstone);
    return { ...tombstone };
  }

  async listEntriesAfter(userId, after, limit) {
    return [...this.entries.values()]
      .filter((e) => e.userId === userId && e.revision > after)
      .sort((a, b) => a.revision - b.revision)
      .slice(0, limit)
      .map((e) => ({ ...e }));
  }

  async liveEntriesBetween(userId, startDate, endDate) {
    return [...this.entries.values()]
      .filter((e) => e.userId === userId && !e.deletedAt && e.entryDate >= startDate && e.entryDate <= endDate)
      .sort((a, b) => a.entryDate.localeCompare(b.entryDate) || a.createdAt.localeCompare(b.createdAt))
      .map((e) => ({ ...e }));
  }

  async deleteUser(userId) {
    this.users.delete(userId);
    await this.deleteSessionsForUser(userId);
    for (const [id, e] of this.entries) if (e.userId === userId) this.entries.delete(id);
  }

  async health() {
    return true;
  }
}

function isoDate(value) {
  if (value instanceof Date) return value.toISOString().slice(0, 10);
  return String(value).slice(0, 10);
}

function iso(value) {
  return value instanceof Date ? value.toISOString() : value === null ? null : new Date(value).toISOString();
}

function entryFromRow(r) {
  return {
    id: r.id,
    userId: r.user_id,
    entryDate: isoDate(r.entry_date),
    createdAt: iso(r.created_at),
    updatedAt: iso(r.updated_at),
    source: r.source,
    private: r.private,
    keyId: r.key_id,
    nonce: r.nonce,
    ciphertext: r.ciphertext,
    deletedAt: r.deleted_at ? iso(r.deleted_at) : null,
    revision: Number(r.revision)
  };
}

function userFromRow(r) {
  return { id: r.id, appleSub: r.apple_sub, email: r.email, createdAt: iso(r.created_at) };
}

export class PostgresStore {
  constructor(connectionString, { max = 5 } = {}) {
    // DATE columns come back as plain 'YYYY-MM-DD' strings, never shifted by a timezone.
    pg.types.setTypeParser(1082, (v) => v);
    this.pool = new pg.Pool({ connectionString, max });
  }

  async close() {
    await this.pool.end();
  }

  async upsertUserByApple({ appleSub, email }) {
    const { rows } = await this.pool.query(
      `INSERT INTO journal_users (id, apple_sub, email) VALUES ($1, $2, $3)
       ON CONFLICT (apple_sub) DO UPDATE SET email = EXCLUDED.email
       RETURNING *`,
      [crypto.randomUUID(), appleSub, email]
    );
    return userFromRow(rows[0]);
  }

  async getUser(id) {
    const { rows } = await this.pool.query("SELECT * FROM journal_users WHERE id = $1", [id]);
    return rows[0] ? userFromRow(rows[0]) : null;
  }

  async findUserByEmail(email) {
    const { rows } = await this.pool.query(
      "SELECT * FROM journal_users WHERE lower(email) = lower($1) ORDER BY created_at LIMIT 1",
      [email]
    );
    return rows[0] ? userFromRow(rows[0]) : null;
  }

  async createSession(userId, tokenHash, expiresAt) {
    await this.pool.query(
      "INSERT INTO journal_sessions (token_hash, user_id, expires_at) VALUES ($1, $2, $3)",
      [tokenHash, userId, expiresAt]
    );
  }

  async takeSession(tokenHash) {
    const { rows } = await this.pool.query(
      "DELETE FROM journal_sessions WHERE token_hash = $1 RETURNING user_id, expires_at",
      [tokenHash]
    );
    if (!rows[0] || new Date(rows[0].expires_at) <= new Date()) return null;
    return { userId: rows[0].user_id };
  }

  async deleteSessionsForUser(userId) {
    await this.pool.query("DELETE FROM journal_sessions WHERE user_id = $1", [userId]);
  }

  async putEntry(row) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const { rows: found } = await client.query("SELECT * FROM journal_entries WHERE id = $1 FOR UPDATE", [row.id]);
      const existing = found[0] ? entryFromRow(found[0]) : null;
      if (existing && existing.userId !== row.userId) throw new ConflictError("entry id belongs to another user");
      if (existing && (existing.deletedAt || !newer(row, existing))) {
        await client.query("COMMIT");
        return existing;
      }
      const { rows } = await client.query(
        `INSERT INTO journal_entries
           (id, user_id, entry_date, created_at, updated_at, source, private, key_id, nonce, ciphertext, deleted_at, revision)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NULL, nextval('journal_entry_revision'))
         ON CONFLICT (id) DO UPDATE SET
           entry_date = EXCLUDED.entry_date, updated_at = EXCLUDED.updated_at, source = EXCLUDED.source,
           private = EXCLUDED.private, key_id = EXCLUDED.key_id, nonce = EXCLUDED.nonce,
           ciphertext = EXCLUDED.ciphertext, revision = EXCLUDED.revision
         RETURNING *`,
        [row.id, row.userId, row.entryDate, row.createdAt, row.updatedAt, row.source, row.private,
          row.keyId, row.nonce, row.ciphertext]
      );
      await client.query("COMMIT");
      return entryFromRow(rows[0]);
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  async deleteEntry(userId, id, deletedAt) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const { rows: found } = await client.query("SELECT * FROM journal_entries WHERE id = $1 FOR UPDATE", [id]);
      const existing = found[0] ? entryFromRow(found[0]) : null;
      if (existing && existing.userId !== userId) throw new ConflictError("entry id belongs to another user");
      if (existing?.deletedAt) {
        await client.query("COMMIT");
        return existing;
      }
      const { rows } = await client.query(
        `INSERT INTO journal_entries
           (id, user_id, entry_date, created_at, updated_at, source, private, key_id, nonce, ciphertext, deleted_at, revision)
         VALUES ($1, $2, $3::timestamptz::date, $3, $3, 'text', false, NULL, NULL, NULL, $3, nextval('journal_entry_revision'))
         ON CONFLICT (id) DO UPDATE SET
           updated_at = EXCLUDED.updated_at, key_id = NULL, nonce = NULL, ciphertext = NULL,
           deleted_at = EXCLUDED.deleted_at, revision = EXCLUDED.revision
         RETURNING *`,
        [id, userId, deletedAt]
      );
      await client.query("COMMIT");
      return entryFromRow(rows[0]);
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  async listEntriesAfter(userId, after, limit) {
    const { rows } = await this.pool.query(
      "SELECT * FROM journal_entries WHERE user_id = $1 AND revision > $2 ORDER BY revision LIMIT $3",
      [userId, after, limit]
    );
    return rows.map(entryFromRow);
  }

  async liveEntriesBetween(userId, startDate, endDate) {
    const { rows } = await this.pool.query(
      `SELECT * FROM journal_entries
       WHERE user_id = $1 AND deleted_at IS NULL AND entry_date BETWEEN $2 AND $3
       ORDER BY entry_date, created_at`,
      [userId, startDate, endDate]
    );
    return rows.map(entryFromRow);
  }

  async deleteUser(userId) {
    await this.pool.query("DELETE FROM journal_users WHERE id = $1", [userId]);
  }

  async health() {
    await this.pool.query("SELECT 1 FROM journal_entries LIMIT 1");
    return true;
  }
}
