import crypto from "node:crypto";

// Entry content is sealed with AES-256-GCM. The additional authenticated data
// binds each ciphertext to its user and entry id, so a row's ciphertext cannot
// be copied onto another row and still decrypt.
//
// JOURNAL_DATA_KEYS="<id>:<base64 32 bytes>[,<id>:<base64>...]"
// The first key encrypts; every listed key can decrypt (for rotation).

export function parseKeyRing(value) {
  const ring = new Map();
  let activeId = null;
  for (const part of String(value || "").split(",").map((s) => s.trim()).filter(Boolean)) {
    const match = part.match(/^(\d{1,4}):([A-Za-z0-9+/=_-]+)$/);
    if (!match) throw new Error("JOURNAL_DATA_KEYS entries must look like <id>:<base64 key>");
    const id = Number(match[1]);
    const key = Buffer.from(match[2], "base64");
    if (id < 1 || id > 32767) throw new Error("JOURNAL_DATA_KEYS key id must be 1-32767");
    if (key.length !== 32) throw new Error(`JOURNAL_DATA_KEYS key ${id} must be 32 bytes`);
    if (ring.has(id)) throw new Error(`JOURNAL_DATA_KEYS lists key ${id} twice`);
    ring.set(id, key);
    activeId ??= id;
  }
  if (!ring.size) throw new Error("JOURNAL_DATA_KEYS is required");
  return { ring, activeId };
}

function aad(userId, entryId) {
  return Buffer.from(`journal:v1:${userId}:${entryId}`);
}

export function seal(keys, userId, entryId, content) {
  const key = keys.ring.get(keys.activeId);
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(aad(userId, entryId));
  const body = Buffer.concat([cipher.update(JSON.stringify(content), "utf8"), cipher.final()]);
  return { keyId: keys.activeId, nonce, ciphertext: Buffer.concat([body, cipher.getAuthTag()]) };
}

export function open(keys, userId, entryId, { keyId, nonce, ciphertext }) {
  const key = keys.ring.get(Number(keyId));
  if (!key) throw new Error(`no decryption key ${keyId}`);
  const data = Buffer.from(ciphertext);
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, Buffer.from(nonce));
  decipher.setAAD(aad(userId, entryId));
  decipher.setAuthTag(data.subarray(data.length - 16));
  const plain = Buffer.concat([decipher.update(data.subarray(0, data.length - 16)), decipher.final()]);
  return JSON.parse(plain.toString("utf8"));
}

export function sha256Hex(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex");
}

export function constantTimeEqualHex(a, b) {
  const left = Buffer.from(String(a), "hex");
  const right = Buffer.from(String(b), "hex");
  return left.length === right.length && left.length > 0 && crypto.timingSafeEqual(left, right);
}
