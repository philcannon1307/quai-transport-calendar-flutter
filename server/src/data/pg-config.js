// TLS settings for the Postgres connection.
//  * sslmode=disable, localhost and the Railway private network (*.railway.internal): no TLS (private link).
//  * DATABASE_CA_CERT (PEM text, or base64 of it): verify the server certificate against that CA.
//  * Railway's public TCP proxy (*.rlwy.net) uses a self-signed certificate: encrypted but not verified,
//    and ONLY for those hosts (or when PG_SSL_INSECURE=true is set on purpose).
//  * Anything else: full certificate verification.
export function pgSsl(databaseUrl, env = process.env) {
  if (/[?&]sslmode=disable/.test(databaseUrl)) return undefined;
  let host = "";
  try { host = new URL(databaseUrl).hostname.toLowerCase(); } catch { /* pg reports a bad URL itself */ }
  if (host === "localhost" || host === "127.0.0.1" || host.endsWith(".railway.internal")) return undefined;
  const ca = env.DATABASE_CA_CERT ?? "";
  if (ca) return { ca: ca.includes("BEGIN CERTIFICATE") ? ca : Buffer.from(ca, "base64").toString("utf8"), rejectUnauthorized: true };
  if (host.endsWith(".rlwy.net") || env.PG_SSL_INSECURE === "true") return { rejectUnauthorized: false };
  return { rejectUnauthorized: true };
}
