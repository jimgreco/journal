import { test } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import { parseKeyRing, seal, open } from "../src/crypto.js";

const k1 = crypto.randomBytes(32).toString("base64");
const k2 = crypto.randomBytes(32).toString("base64");

test("seal and open round-trip", () => {
  const keys = parseKeyRing(`1:${k1}`);
  const sealed = seal(keys, "u1", "e1", { text: "hello", mood: 3 });
  assert.deepEqual(open(keys, "u1", "e1", sealed), { text: "hello", mood: 3 });
});

test("ciphertext is bound to its user and entry", () => {
  const keys = parseKeyRing(`1:${k1}`);
  const sealed = seal(keys, "u1", "e1", { text: "hello" });
  assert.throws(() => open(keys, "u2", "e1", sealed));
  assert.throws(() => open(keys, "u1", "e2", sealed));
});

test("tampering is detected", () => {
  const keys = parseKeyRing(`1:${k1}`);
  const sealed = seal(keys, "u1", "e1", { text: "hello" });
  sealed.ciphertext[0] ^= 1;
  assert.throws(() => open(keys, "u1", "e1", sealed));
});

test("rotation: new key encrypts, old key still decrypts", () => {
  const old = parseKeyRing(`1:${k1}`);
  const sealedOld = seal(old, "u", "e", { text: "old" });
  const rotated = parseKeyRing(`2:${k2},1:${k1}`);
  assert.equal(rotated.activeId, 2);
  assert.equal(seal(rotated, "u", "e", { text: "new" }).keyId, 2);
  assert.deepEqual(open(rotated, "u", "e", sealedOld), { text: "old" });
});

test("key ring rejects bad input", () => {
  assert.throws(() => parseKeyRing(""));
  assert.throws(() => parseKeyRing("1:c2hvcnQ="));
  assert.throws(() => parseKeyRing(`1:${k1},1:${k2}`));
  assert.throws(() => parseKeyRing(`nokey`));
});
