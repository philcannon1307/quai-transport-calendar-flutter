import { createHmac, timingSafeEqual, randomUUID } from "node:crypto";

// HS256 session JWT. Signed with SESSION_JWT_SECRET. Set that to the Supabase project's
// JWT secret and Supabase RLS can read the claims with auth.jwt() ->> 'app_role'.
const b64u = (buf) => Buffer.from(buf).toString("base64url");
const HEADER = b64u(JSON.stringify({ alg: "HS256", typ: "JWT" }));

export const ISSUER = "quai-exchange";
export const AUDIENCE = "authenticated";

function sign(data, secret) {
  return createHmac("sha256", secret).update(data).digest();
}

/**
 * claims: { sub, appRole, trucks, names }
 * "role" is the Postgres role Supabase expects ("authenticated"); the application
 * role (carrier | logistique | superuser) is "app_role".
 */
export function signSession({ sub, appRole, trucks, names = [] }, secret, ttlSeconds, nowMs = Date.now()) {
  const iat = Math.floor(nowMs / 1000);
  const exp = iat + ttlSeconds;
  const payload = {
    iss: ISSUER,
    aud: AUDIENCE,
    role: "authenticated",
    sub,
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
