import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { signSession, verifySession, uuidV5, subjectFor } from "../src/jwt.js";

const S = "x".repeat(40);

test("sign + verify round trip carries Supabase-compatible claims", () => {
  const { token, exp } = signSession({ carrier: "InterQL", appRole: "carrier", trucks: ["3", "4"] }, S, 600);
  const p = verifySession(token, S);
  assert.equal(p.carrier, "InterQL");
  assert.match(p.sub, /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/, "sub is a UUID v5");
  assert.equal(p.sub, subjectFor("InterQL"));
  assert.equal(p.app_role, "carrier");
  assert.equal(p.role, "authenticated");
  assert.equal(p.aud, "authenticated");
  assert.deepEqual(p.trucks, ["3", "4"]);
  assert.equal(p.exp, exp);
  assert.equal(p.exp - p.iat, 600);
});

test("uuid v5 matches the RFC / Python reference and is deterministic", () => {
  // python3: uuid.uuid5(uuid.UUID("6f1d0c52-8a3e-4b7a-9d41-2c7e0b9a4f10"), "gat - sam")
  assert.equal(subjectFor("Gat - Sam"), "e28d89af-32c8-5250-9b81-dd2a8f508d77");
  assert.equal(subjectFor(" gat - SAM "), subjectFor("Gat - Sam"));
  assert.notEqual(subjectFor("Gat - Sam"), subjectFor("Gat - Sam2"));
  // RFC 4122 appendix test vector: uuid5(DNS namespace, "python.org")
  assert.equal(uuidV5("python.org", "6ba7b810-9dad-11d1-80b4-00c04fd430c8"), "886313e1-3b8a-5372-9b90-0c9aee199e5d");
});

test("rejects wrong secret, tampered payload, expiry, alg none, garbage", () => {
  const { token } = signSession({ carrier: "a", appRole: "carrier", trucks: [] }, S, 60, 1_000_000);
  assert.equal(verifySession(token, "y".repeat(40), 1_000_000), null);
  assert.equal(verifySession(token, S, 1_000_000 + 61_000), null, "expired");
  const [h, p, s] = token.split(".");
  const evil = Buffer.from(JSON.stringify({ ...JSON.parse(Buffer.from(p, "base64url")), app_role: "superuser" })).toString("base64url");
  assert.equal(verifySession([h, evil, s].join("."), S, 1_000_000), null, "payload tampered");
  const none = Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" })).toString("base64url");
  assert.equal(verifySession([none, p, ""].join("."), S, 1_000_000), null, "alg none");
  const hs512 = Buffer.from(JSON.stringify({ alg: "HS512", typ: "JWT" })).toString("base64url");
  const sig = createHmac("sha256", S).update(hs512 + "." + p).digest("base64url");
  assert.equal(verifySession([hs512, p, sig].join("."), S, 1_000_000), null, "other alg");
  assert.equal(verifySession("nope", S), null);
  assert.equal(verifySession(undefined, S), null);
});
