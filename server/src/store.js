import crypto from "node:crypto";
import pg from "pg";

// Two stores with the same contract: MemoryStore for tests and local
// development, PostgresStore for production. Rows hold ciphertext only; the
// app layer encrypts and decrypts.
//
// Entry row: { id, userId, entryDate, createdAt, updatedAt, source, private,
//              keyId, nonce, ciphertext, deletedAt, revision }
// putEntry also takes photoIds: the photos the entry keeps. When the write is
// applied, the entry's other photos are deleted; deleting an entry deletes
// all of its photos.
//
// Photo row: { id, userId, entryId, keyId, nonce, ciphertext }

export class ConflictError extends Error {}

function newer(incoming, existing) {
  return new Date(incoming.updatedAt).getTime() >= new Date(existing.updatedAt).getTime();
}

export class MemoryStore {
  constructor() {
    this.users = new Map();
    this.identities = new Map(); // "provider:subject" -> userId
    this.sessions = new Map();
    this.entries = new Map();
    this.photos = new Map();
    this.revision = 0;
  }

  // Finds the user for a sign-in identity, linking it to the user with the same
  // verified email, or creating one. Unverified emails never link accounts.
  async upsertUserByIdentity({ provider, subject, email, emailVerified }) {
    const key = `${provider}:${subject}`;
    let user = this.users.get(this.identities.get(key));
    if (!user && emailVerified) {
      const wanted = email.toLowerCase();
      user = [...this.users.values()].find((u) => u.email.toLowerCase() === wanted);
    }
    if (!user) {
      user = { id: crypto.randomUUID(), email, createdAt: new Date().toISOString() };
      this.users.set(user.id, user);
    }
    this.identities.set(key, user.id);
    if (emailVerified) user.email = email;
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
    const { photoIds = [], ...fields } = row;
    const stored = {
      ...fields,
      createdAt: existing?.createdAt ?? row.createdAt,
      deletedAt: null,
      revision: ++this.revision
    };
    this.entries.set(row.id, stored);
    this.#prunePhotos(row.userId, row.id, photoIds);
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
    this.#prunePhotos(userId, id, []);
    return { ...tombstone };
  }

  #prunePhotos(userId, entryId, keep) {
    for (const [id, p] of this.photos) {
      if (p.userId === userId && p.entryId === entryId && !keep.includes(id)) this.photos.delete(id);
    }
  }

  // Photos never change, so a repeated upload (a retry) keeps the first copy.
  async putPhoto(row) {
    const existing = this.photos.get(row.id);
    if (existing && existing.userId !== row.userId) throw new ConflictError("photo id belongs to another user");
    if (!existing) this.photos.set(row.id, { ...row });
  }

  async getPhoto(userId, id) {
    const photo = this.photos.get(id);
    return photo && photo.userId === userId ? { ...photo } : null;
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
    for (const [key, id] of this.identities) if (id === userId) this.identities.delete(key);
    await this.deleteSessionsForUser(userId);
    for (const [id, e] of this.entries) if (e.userId === userId) this.entries.delete(id);
    for (const [id, p] of this.photos) if (p.userId === userId) this.photos.delete(id);
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
  return { id: r.id, email: r.email, createdAt: iso(r.created_at) };
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

  async upsertUserByIdentity({ provider, subject, email, emailVerified }) {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      // One sign-in at a time decides linking, so two first sign-ins can't create two users.
      await client.query("SELECT pg_advisory_xact_lock(hashtext('journal-identity'))");
      let { rows } = await client.query(
        `SELECT u.* FROM journal_identities i JOIN journal_users u ON u.id = i.user_id
         WHERE i.provider = $1 AND i.subject = $2`,
        [provider, subject]
      );
      if (!rows[0] && emailVerified) {
        ({ rows } = await client.query(
          "SELECT * FROM journal_users WHERE lower(email) = lower($1) ORDER BY created_at LIMIT 1",
          [email]
        ));
      }
      if (!rows[0]) {
        ({ rows } = await client.query(
          "INSERT INTO journal_users (id, email) VALUES ($1, $2) RETURNING *",
          [crypto.randomUUID(), email]
        ));
      }
      const userId = rows[0].id;
      await client.query(
        `INSERT INTO journal_identities (provider, subject, user_id) VALUES ($1, $2, $3)
         ON CONFLICT (provider, subject) DO NOTHING`,
        [provider, subject, userId]
      );
      if (emailVerified) {
        ({ rows } = await client.query("UPDATE journal_users SET email = $2 WHERE id = $1 RETURNING *", [userId, email]));
      }
      await client.query("COMMIT");
      return userFromRow(rows[0]);
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
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
      await client.query(
        "DELETE FROM journal_photos WHERE user_id = $1 AND entry_id = $2 AND NOT (id = ANY($3::uuid[]))",
        [row.userId, row.id, row.photoIds ?? []]
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
      await client.query("DELETE FROM journal_photos WHERE user_id = $1 AND entry_id = $2", [userId, id]);
      await client.query("COMMIT");
      return entryFromRow(rows[0]);
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  async putPhoto(row) {
    await this.pool.query(
      `INSERT INTO journal_photos (id, user_id, entry_id, key_id, nonce, ciphertext)
       VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (id) DO NOTHING`,
      [row.id, row.userId, row.entryId, row.keyId, row.nonce, row.ciphertext]
    );
    const { rows } = await this.pool.query("SELECT user_id FROM journal_photos WHERE id = $1", [row.id]);
    if (rows[0]?.user_id !== row.userId) throw new ConflictError("photo id belongs to another user");
  }

  async getPhoto(userId, id) {
    const { rows } = await this.pool.query(
      "SELECT * FROM journal_photos WHERE id = $1 AND user_id = $2",
      [id, userId]
    );
    const r = rows[0];
    return r ? { id: r.id, userId: r.user_id, entryId: r.entry_id, keyId: r.key_id, nonce: r.nonce, ciphertext: r.ciphertext } : null;
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
