import { scryptSync, randomBytes } from "node:crypto";
import { orderChangeSettings } from "./data/orderChanges.js";
import { CARRIERS, SUPERUSER_NAME, allAccounts, normName } from "./roster.js";

export const DEFAULT_MIDDLEWARE_URL = "https://quai-backend-methods-production.up.railway.app";
export const DEFAULT_JOB_SERVICE_URL = "https://quai-contractor-calendar-production.up.railway.app";

/** "scrypt$<salt b64>$<hash b64>" -- produced by `npm run hash-password`. */
export function hashPassword(password) {
  const salt = randomBytes(16);
  const hash = scryptSync(password, salt, 32);
  return "scrypt$" + salt.toString("base64") + "$" + hash.toString("base64");
}

function int(env, name, def, min, max, errors) {
  const raw = env[name];
  if (raw === undefined || raw === "") return def;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < min || n > max) {
    errors.push(name + " must be a whole number between " + min + " and " + max + ".");
    return def;
  }
  return n;
}

/**
 * Reads and validates the environment. Never throws: returns { config, errors, warnings }.
 * The server refuses to start when errors is not empty. Messages never contain secret values.
 */
export function loadConfig(env = process.env) {
  const errors = [];
  const warnings = [];

  // --- carrier credentials -------------------------------------------------
  const credentials = new Map(); // name -> { code?, password? }
  const rawCreds = env.CARRIER_CREDENTIALS_JSON;
  if (!rawCreds) {
    errors.push("CARRIER_CREDENTIALS_JSON is required.");
  } else {
    try {
      const parsed = JSON.parse(rawCreds);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("not an object");
      for (const [name, v] of Object.entries(parsed)) {
        if (typeof v === "string" && v) credentials.set(name, { code: v, password: v });
        else if (v && typeof v === "object" && !Array.isArray(v)) {
          const code = typeof v.code === "string" && v.code ? v.code : undefined;
          const password = typeof v.password === "string" && v.password ? v.password : undefined;
          if (!code && !password) errors.push('CARRIER_CREDENTIALS_JSON entry "' + name + '" needs a "code" or a "password".');
          else credentials.set(name, { code: code ?? password, password: password ?? code });
        } else errors.push('CARRIER_CREDENTIALS_JSON entry "' + name + '" must be a string or {code, password}.');
      }
    } catch {
      errors.push("CARRIER_CREDENTIALS_JSON is not valid JSON (it must be one JSON object).");
    }
    // Accent/case/space-insensitive: a credentials key spelled "SADM - Eric" serves the roster name "SADM - Éric".
    const byNorm = new Map();
    for (const [k, v] of credentials) if (!byNorm.has(normName(k))) byNorm.set(normName(k), v);
    for (const n of [...CARRIERS.map((c) => c.displayName), ...allAccounts().map((a) => a.username)]) {
      if (!credentials.has(n) && byNorm.has(normName(n))) credentials.set(n, byNorm.get(normName(n)));
    }
    const missing = CARRIERS.filter((c) => !credentials.has(c.displayName)).map((c) => c.displayName);
    if (missing.length) warnings.push("No credentials for these logins, so they are disabled: " + missing.join(", "));
  }

  // --- session JWT ---------------------------------------------------------
  const sessionSecret = env.SESSION_JWT_SECRET ?? "";
  if (sessionSecret.length < 32) errors.push("SESSION_JWT_SECRET is required and must be at least 32 characters.");

  const sessionTtlSeconds = int(env, "SESSION_TTL_SECONDS", 43200, 60, 86400, errors);

  // --- CORS ------------------------------------------------------------------
  const allowedOrigins = new Set();
  const rawOrigins = env.ALLOWED_ORIGINS ?? "";
  for (const o of rawOrigins.split(",").map((s) => s.trim()).filter(Boolean)) {
    if (o === "*") { errors.push('ALLOWED_ORIGINS must list exact origins; "*" is not accepted.'); continue; }
    try {
      const u = new URL(o);
      if (u.origin !== o.replace(/\/$/, "")) throw new Error();
      if (u.protocol !== "https:" && !/^(localhost|127\.0\.0\.1)$/.test(u.hostname)) {
        errors.push("ALLOWED_ORIGINS entry " + o + " must be https (http only for localhost).");
        continue;
      }
      allowedOrigins.add(u.origin);
    } catch {
      errors.push("ALLOWED_ORIGINS entry is not a valid origin like https://app.example.com : " + o);
    }
  }
  if (allowedOrigins.size === 0 && rawOrigins.trim() === "") errors.push("ALLOWED_ORIGINS is required (comma-separated list of app origins).");

  // --- job service -----------------------------------------------------------
  const jobServiceUrl = (env.JOB_SERVICE_URL || DEFAULT_JOB_SERVICE_URL).replace(/\/+$/, "");
  try {
    const u = new URL(jobServiceUrl);
    if (u.protocol !== "https:" && !/^(localhost|127\.0\.0\.1)$/.test(u.hostname)) errors.push("JOB_SERVICE_URL must be https.");
  } catch {
    errors.push("JOB_SERVICE_URL is not a valid URL.");
  }
  const jobTimeoutMs = int(env, "JOB_TIMEOUT_MS", 15000, 1000, 60000, errors);

  // --- SuperUser -------------------------------------------------------------
  let superUser = null;
  const suName = env.SUPERUSER_USERNAME ?? "";
  const suHash = env.SUPERUSER_PASSWORD_HASH ?? "";
  const suPlain = env.SUPERUSER_PASSWORD ?? "";
  if (suName && (suHash || suPlain)) {
    if (suHash && !/^scrypt\$[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+$/.test(suHash)) {
      errors.push("SUPERUSER_PASSWORD_HASH has the wrong format (create it with: npm run hash-password).");
    } else {
      superUser = { username: suName, passwordHash: suHash || null, password: suHash ? null : suPlain };
    }
  } else {
    warnings.push("SUPERUSER_USERNAME / SUPERUSER_PASSWORD_HASH not set: the /admin SuperUser login is disabled.");
  }

  // --- Pick-ups proxy (middleware) --------------------------------------------
  const middlewareUrl = (env.MIDDLEWARE_URL || DEFAULT_MIDDLEWARE_URL).replace(/\/+$/, "");
  try {
    const u = new URL(middlewareUrl);
    if (u.protocol !== "https:" && !/^(localhost|127\.0\.0\.1)$/.test(u.hostname)) errors.push("MIDDLEWARE_URL must be https.");
  } catch {
    errors.push("MIDDLEWARE_URL is not a valid URL.");
  }
  const middlewareTimeoutMs = int(env, "MIDDLEWARE_TIMEOUT_MS", 15000, 1000, 60000, errors);
  const middlewareApiKey = env.MIDDLEWARE_API_KEY ?? "";
  if (!middlewareApiKey) warnings.push("MIDDLEWARE_API_KEY not set: the Pick-ups proxy answers 503 until it is.");

  // --- Data API (replaces the Lovable Cloud / Supabase project) ------------------
  const databaseUrl = env.DATABASE_URL ?? "";
  const dataStore = databaseUrl ? "postgres" : env.DATA_STORE === "memory" ? "memory" : null;
  const publicBaseUrl = (env.PUBLIC_BASE_URL ?? "").replace(/\/+$/, "");
  if (dataStore === "memory" && env.NODE_ENV === "production") errors.push("DATA_STORE=memory is for development only and is refused when NODE_ENV=production: set DATABASE_URL.");
  if (dataStore) {
    try {
      const u = new URL(publicBaseUrl);
      if (u.protocol !== "https:" && !/^(localhost|127\.0\.0\.1)$/.test(u.hostname)) throw new Error();
    } catch {
      errors.push("PUBLIC_BASE_URL is required with the data API: this server's public https address (used in picture links).");
    }
  } else {
    warnings.push("DATABASE_URL not set: the data API (announcements, receipts, change reports, history, email) answers 503.");
  }
  const emailProvider = (env.EMAIL_PROVIDER ?? "log").toLowerCase();
  if (!["resend", "sendgrid", "log"].includes(emailProvider)) errors.push("EMAIL_PROVIDER must be resend, sendgrid or log.");
  if (dataStore && emailProvider !== "log" && !env.EMAIL_API_KEY) errors.push("EMAIL_API_KEY is required for EMAIL_PROVIDER=" + emailProvider + ".");
  if (dataStore && emailProvider === "log") warnings.push("EMAIL_PROVIDER=log: emails are NOT sent (only logged). Set EMAIL_PROVIDER and EMAIL_API_KEY.");
  const oc = orderChangeSettings(env);
  errors.push(...oc.errors);
  const emailFrom = env.EMAIL_FROM || "Groupe QL Transport <noreply@notify.groupeql.com>";

  const uploads = {
    perHour: int(env, "UPLOAD_MAX_PER_HOUR", 60, 1, 100000, errors),
    mbPerHour: int(env, "UPLOAD_MAX_MB_PER_HOUR", 150, 1, 100000, errors),
    perMinuteIp: int(env, "UPLOAD_MAX_PER_MINUTE_IP", 30, 1, 100000, errors),
    storageAlarmMb: int(env, "STORAGE_ALARM_MB", 2000, 1, 10000000, errors),
  };
  const trustProxyHops = int(env, "TRUST_PROXY_HOPS", 1, 0, 5, errors);
  const adminAggregate = {
    enabled: !/^(0|false|off|no)$/i.test(String(env.ADMIN_AGGREGATE_ENABLED ?? "")),
    intervalSeconds: int(env, "ADMIN_AGGREGATE_REFRESH_SECONDS", 300, 30, 3600, errors),
    truckTimeoutMs: int(env, "ADMIN_AGGREGATE_TRUCK_TIMEOUT_MS", 40000, 1000, 120000, errors),
  };
  const port = int(env, "PORT", 3000, 1, 65535, errors);

  return {
    errors,
    warnings,
    config: {
      port, credentials, sessionSecret, sessionTtlSeconds, allowedOrigins, jobServiceUrl, jobTimeoutMs,
      superUser, trustProxyHops, adminAggregate,
      data: {
        store: dataStore, databaseUrl, publicBaseUrl, uploads, emailFrom, publicSiteUrl: env.PUBLIC_SITE_URL ?? "", orderChanges: oc.settings,
        email: { provider: emailProvider, apiKey: env.EMAIL_API_KEY ?? "", replyTo: env.EMAIL_REPLY_TO ?? "" },
      },
      middleware: { url: middlewareUrl, apiKey: middlewareApiKey, timeoutMs: middlewareTimeoutMs },
      // Brute-force defences (see README "Security").
      limits: {
        perIpRequests: { max: 30, windowMs: 60_000 },
        carrierPerIp: { max: 5, windowMs: 10 * 60_000, lockMs: 15 * 60_000 },
        carrierGlobal: { max: 20, windowMs: 60 * 60_000, lockMs: 30 * 60_000 },
        superPerIp: { max: 3, windowMs: 30 * 60_000, lockMs: 30 * 60_000 },
        middlewarePerIp: { max: 120, windowMs: 60_000 },
        middlewarePerSession: { max: 60, windowMs: 60_000 },
        superGlobal: { max: 10, windowMs: 60 * 60_000, lockMs: 60 * 60_000 },
      },
    },
  };
}

export { SUPERUSER_NAME };
