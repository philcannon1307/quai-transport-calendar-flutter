import { createHash, createHmac, timingSafeEqual, randomUUID } from "node:crypto";

// HS256 session JWT. Signed with SESSION_JWT_SECRET, a random 32+ character value that only this
// server and the Supabase edge functions (quai-data, send-transactional-email) know. The edge
// functions verify the token themselves (supabase/functions/quai-data/guard.ts) and read the claims
// carrier / app_role / names. Supabase's own JWT secret is NOT used (Lovable Cloud does not expose it).
const b64u = (buf) => Buffer.from(buf).toString("base64url");
const HEADER = b64u(JSON.stringify({ alg: "HS256", typ: "JWT" }));

export const ISSUER = "quai-exchange";
export const AUDIENCE = "authenticated";

// Fixed namespace for carrier subjects. Never change it: ids stored by Storage (owner) derive from it.
export const SUBJECT_NAMESPACE = "6f1d0c52-8a3e-4b7a-9d41-2c7e0b9a4f10";

/** RFC 4122 UUID v5 (SHA-1) of name in namespace. */
export function uuidV5(name, namespace = SUBJECT_NAMESPACE) {
  const ns = Buffer.from(namespace.replace(/-/g, ""), "hex");
  const h = createHash("sha1").update(ns).update(Buffer.from(String(name), "utf8")).digest().subarray(0, 16);
  h[6] = (h[6] & 0x0f) | 0x50;
  h[8] = (h[8] & 0x3f) | 0x80;
  const x = h.toString("hex");
  return x.slice(0, 8) + "-" + x.slice(8, 12) + "-" + x.slice(12, 16) + "-" + x.slice(16, 20) + "-" + x.slice(20);
}
export const subjectFor = (carrier) => uuidV5(String(carrier).trim().toLowerCase());

function sign(data, secret) {
  return createHmac("sha256", secret).update(data).digest();
}

/**
 * claims: { carrier, appRole, trucks, names }
 * "sub" is a deterministic UUID (v5 of the carrier name) so Supabase Storage / auth.uid() never choke
 * on a non-UUID subject; the readable carrier name travels in the separate "carrier" claim.
 * "role" is the Postgres role Supabase expects ("authenticated"); the application
 * role (carrier | logistique | superuser) is "app_role".
 */
export function signSession({ carrier, appRole, trucks, names = [] }, secret, ttlSeconds, nowMs = Date.now()) {
  const iat = Math.floor(nowMs / 1000);
  const exp = iat + ttlSeconds;
  const payload = {
    iss: ISSUER,
    aud: AUDIENCE,
    role: "authenticated",
    sub: subjectFor(carrier),
    carrier,
    app_role: appRole,
    trucks,
    names, // every name this login's rows may carry (delivery_history.carrier_name)
    iat,
    exp,
    jti: randomUUID(),
  };
  const body = HEADER + "." + b64u(JSON.stringify(payload));
  return { token: body + "." + b64u(sign(body, secret)), exp, payload };
}

/** Returns the payload, or null for anything invalid / expired / wrong algorithm. */
export function verifySession(token, secret, nowMs = Date.now()) {
  if (typeof token !== "string") return null;
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const [h, p, s] = parts;
  try {
    const header = JSON.parse(Buffer.from(h, "base64url").toString("utf8"));
    if (!header || header.alg !== "HS256") return null; // never accept "none" or other algs
    const expected = sign(h + "." + p, secret);
    const given = Buffer.from(s, "base64url");
    if (given.length !== expected.length || !timingSafeEqual(given, expected)) return null;
    const payload = JSON.parse(Buffer.from(p, "base64url").toString("utf8"));
    if (payload.iss !== ISSUER || payload.aud !== AUDIENCE) return null;
    if (typeof payload.exp !== "number" || payload.exp <= Math.floor(nowMs / 1000)) return null;
    return payload;
  } catch {
    return null;
  }
}
