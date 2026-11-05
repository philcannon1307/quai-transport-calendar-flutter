// HTTP surface of the data API. The paths deliberately mirror the Supabase ones the Flutter app already
// calls, so moving over is a configuration change (QUAI_BACKEND_URL), not a code change:
//   POST /functions/v1/quai-data                    JSON {op, ...}  or  ?op=upload&bucket=&path= with the raw picture
//   POST /functions/v1/send-transactional-email
//   GET|POST /functions/v1/handle-email-unsubscribe
//   GET  /rest/v1/announcements | /rest/v1/announcement_images     (public read of active announcements)
//   GET  /storage/v1/object/public/<bucket>/<path>                  (public pictures)
import { RateLimiter } from "../limiter.js";
import { UploadQuota } from "./quota.js";
import { encodePath, isUuid, sessionFromToken, sessionTokenFrom } from "./guard.js";
import { HttpError, MAX_JSON_BYTES, MAX_UPLOAD_BYTES, run, upload } from "./handler.js";
import { handleUnsubscribe, sendTransactional } from "./email.js";
import { createOrderChanges, orderChangeSettings, validateOrderNum } from "./orderChanges.js";
import { createPrepState, strictOrderNum } from "./prepState.js";

const PUBLIC_BUCKETS = new Set(["announcement-images", "receipts"]);
// CORS: data routes answer only the origins on ALLOWED_ORIGINS (the same list as the exchange). The only
// wildcard is for public pictures (GET /storage/...), which are public by design. Auth is a bearer token.
const CORS_COMMON = {
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-quai-session, x-supabase-api-version",
  "Access-Control-Allow-Methods": "GET, POST, PUT, OPTIONS",
  "Access-Control-Max-Age": "600",
};

export function isDataPath(path) {
  return path.startsWith("/functions/v1/") || path.startsWith("/orders/") || path === "/prep-state" || path.startsWith("/prep-state/") || path.startsWith("/rest/v1/") || path.startsWith("/storage/v1/object/public/");
}

function readBytes(req, max) {
  return new Promise((resolve, reject) => {
    const declared = Number(req.headers["content-length"] ?? 0);
    if (declared > max) return reject(new HttpError(413, "too_large"));
    let size = 0;
    const chunks = [];
    let failed = false;
    req.on("data", (c) => {
      if (failed) return;
      size += c.length;
      if (size > max) { failed = true; chunks.length = 0; reject(new HttpError(413, "too_large")); return; }
      chunks.push(c);
    });
    req.on("end", () => { if (!failed) resolve(Buffer.concat(chunks)); });
    req.on("error", reject);
  });
}

/**
 * ctx: { config, store, provider, now, log }
 * config.data: { publicBaseUrl, emailFrom, publicSiteUrl }
 */
export function createDataApi({ config, store, provider, now = Date.now, log = () => {} }) {
  const baseUrl = (config.data?.publicBaseUrl ?? "").replace(/\/+$/, "");
  const limiter = new RateLimiter({ max: 300, windowMs: 60_000, now });
  const U = { perHour: 60, mbPerHour: 150, perMinuteIp: 30, storageAlarmMb: 2000, ...(config.data?.uploads ?? {}) };
  const uploadIpLimiter = new RateLimiter({ max: U.perMinuteIp, windowMs: 60_000, now });
  const quota = new UploadQuota({ maxCount: U.perHour, maxBytes: U.mbPerHour * 1024 * 1024, now });
  let lastAlarmCheck = 0;
  async function storageAlarm() {
    const t = now();
    if (t - lastAlarmCheck < 600_000 || typeof store?.totalFileBytes !== "function") return;
    lastAlarmCheck = t;
    try {
      const bytes = await store.totalFileBytes();
      if (bytes > U.storageAlarmMb * 1024 * 1024) log("storage_alarm", { bytes, limitBytes: U.storageAlarmMb * 1024 * 1024 });
    } catch { /* an alarm check never fails an upload */ }
  }
  const allowedOrigins = config.allowedOrigins ?? new Set();
  const ocSettings = config.data?.orderChanges ?? orderChangeSettings({}).settings;
  const changeLimiter = new RateLimiter({ max: 20, windowMs: 10 * 60_000, now });
  const previewLimiter = new RateLimiter({ max: 60, windowMs: 10 * 60_000, now });
  const orderChanges = createOrderChanges({
    store, settings: ocSettings, now, log,
    sendEmail: (changeId, s) => sendTransactional({
      body: { templateName: "order-change", idempotencyKey: "order-change:" + changeId, templateData: { changeId } },
      session: s, store, provider, baseUrl, from: config.data.emailFrom, publicSiteUrl: config.data.publicSiteUrl,
    }),
  });

  const prepLimiter = new RateLimiter({ max: 120, windowMs: 60_000, now });
  const prep = createPrepState({ store, now, log });

  function send(res, status, body, extra = {}) {
    res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...extra });
    res.end(body === undefined ? "" : JSON.stringify(body));
  }

  async function readJson(req) {
    const buf = await readBytes(req, MAX_JSON_BYTES);
    try { return JSON.parse(buf.toString("utf8") || "{}"); } catch { throw new HttpError(400, "bad_json"); }
  }

  function session(req) {
    const s = sessionFromToken(sessionTokenFrom(req.headers), config.sessionSecret, now());
    if (!s) throw new HttpError(401, "invalid_session");
    return s;
  }

  async function handle(req, res, ip) {
    const url = new URL(req.url ?? "/", "http://x");
    const path = url.pathname;
    const origin = req.headers.origin;
    const publicPicture = req.method === "GET" && path.startsWith("/storage/v1/object/public/");
    const cors = { ...CORS_COMMON };
    if (publicPicture) cors["Access-Control-Allow-Origin"] = "*";
    else if (origin !== undefined && allowedOrigins.has(origin)) { cors["Access-Control-Allow-Origin"] = origin; cors.Vary = "Origin"; }
    const reply = (status, payload, extra = {}) => send(res, status, payload, { ...cors, ...extra });
    try {
      if (req.method === "OPTIONS") return reply(204, undefined);
      if (origin !== undefined && !publicPicture && !allowedOrigins.has(origin)) return reply(403, { error: "origin_not_allowed" });
      if (!store) throw new HttpError(503, "data_not_configured");
      const wait = limiter.hit(ip);
      if (wait > 0) return reply(429, { error: "too_many_requests", retryAfter: wait }, { "Retry-After": String(wait) });

      // ---- public reads
      if (req.method === "GET" && path === "/rest/v1/announcements") {
        return reply(200, await store.listActiveAnnouncements());
      }
      if (req.method === "GET" && path === "/rest/v1/announcement_images") {
        const m = /^in\.\((.*)\)$/.exec(url.searchParams.get("announcement_id") ?? "");
        const ids = m ? m[1].split(",").map((x) => x.trim()).filter(isUuid).slice(0, 200) : [];
        return reply(200, await store.listAnnouncementImages(ids));
      }
      if (req.method === "GET" && path.startsWith("/storage/v1/object/public/")) {
        const rest = path.slice("/storage/v1/object/public/".length);
        const slash = rest.indexOf("/");
        const bucket = slash > 0 ? rest.slice(0, slash) : "";
        let filePath;
        try { filePath = rest.slice(slash + 1).split("/").map(decodeURIComponent).join("/"); } catch { throw new HttpError(400, "bad_path"); }
        if (!PUBLIC_BUCKETS.has(bucket) || !filePath || filePath.includes("..")) throw new HttpError(404, "not_found");
        const f = await store.getFile(bucket, filePath);
        if (!f) throw new HttpError(404, "not_found");
        res.writeHead(200, {
          "Content-Type": f.type, "Content-Length": f.bytes.length, "Cache-Control": "public, max-age=3600",
          "X-Content-Type-Options": "nosniff", "Content-Security-Policy": "default-src 'none'; sandbox", ...cors,
        });
        return res.end(f.bytes);
      }

      // ---- unsubscribe (public: the token is the credential)
      if (path === "/functions/v1/handle-email-unsubscribe") {
        if (req.method !== "GET" && req.method !== "POST") throw new HttpError(405, "method_not_allowed");
        let token = url.searchParams.get("token");
        if (req.method === "POST") {
          const ct = String(req.headers["content-type"] ?? "");
          const raw = (await readBytes(req, 8 * 1024)).toString("utf8");
          if (ct.includes("application/x-www-form-urlencoded")) {
            const p = new URLSearchParams(raw);
            if (!p.get("List-Unsubscribe") && p.get("token")) token = p.get("token");
          } else {
            try { const b = JSON.parse(raw); if (b && b.token) token = String(b.token); } catch { /* keep query token */ }
          }
        }
        const out = await handleUnsubscribe({ method: req.method, token, store });
        return reply(out.status, out.body);
      }

      // ---- prepared state of an order (signed-in users; writes: logistique + superuser)
      if (path === "/prep-state" || path.startsWith("/prep-state/")) {
        const s = session(req);
        const parts = path.split("/").filter(Boolean); // ["prep-state", NUM?, "history"?]
        if (parts.length === 1) {
          if (req.method !== "GET") throw new HttpError(405, "method_not_allowed");
          return reply(200, await prep.list(url.searchParams, s));
        }
        let num;
        try { num = strictOrderNum(decodeURIComponent(parts[1])); } catch (e) { throw e instanceof HttpError ? e : new HttpError(400, "order_num_invalid"); }
        if (parts.length === 2 && req.method === "PUT") {
          const wait = prepLimiter.hit(s.carrier + "|" + s.uid);
          if (wait > 0) return reply(429, { error: "too_many_requests", retryAfter: wait }, { "Retry-After": String(wait) });
          return reply(200, await prep.set(num, await readJson(req), s));
        }
        if (parts.length === 3 && parts[2] === "history" && req.method === "GET") return reply(200, await prep.history(num, url.searchParams, s));
        if (parts.length > 3 || (parts.length === 3 && parts[2] !== "history")) throw new HttpError(404, "not_found");
        throw new HttpError(405, "method_not_allowed");
      }

      // ---- order change notice (signed-in users)
      if (path.startsWith("/orders/")) {
        const s = session(req);
        const parts = path.split("/").filter(Boolean); // ["orders", X, ...]
        if (parts[1] === "division-contacts" && parts.length === 2) {
          if (req.method === "GET") return reply(200, await orderChanges.listContacts(s));
          if (req.method === "PUT") return reply(200, await orderChanges.putContact(await readJson(req), s));
          throw new HttpError(405, "method_not_allowed");
        }
        if (parts[1] === "changed" && parts.length === 2) {
          if (req.method !== "GET") throw new HttpError(405, "method_not_allowed");
          return reply(200, await orderChanges.changedSummary(url.searchParams.get("nums"), s));
        }
        if (parts.length >= 3 && parts[2] === "changes") {
          const num = validateOrderNum(decodeURIComponent(parts[1]));
          if (parts.length === 3 && req.method === "GET") return reply(200, await orderChanges.history(num, s));
          if (parts.length === 3 && req.method === "POST") {
            const wait = changeLimiter.hit(s.carrier);
            if (wait > 0) return reply(429, { error: "too_many_changes", retryAfter: wait }, { "Retry-After": String(wait) });
            const out = await orderChanges.create(num, await readJson(req), s);
            return reply(out.status, out.body);
          }
          if (parts.length === 4 && parts[3] === "preview" && req.method === "POST") {
            const wait = previewLimiter.hit(s.carrier);
            if (wait > 0) return reply(429, { error: "too_many_changes", retryAfter: wait }, { "Retry-After": String(wait) });
            return reply(200, await orderChanges.preview(num, await readJson(req), s));
          }
          throw new HttpError(405, "method_not_allowed");
        }
        throw new HttpError(404, "not_found");
      }

      // ---- everything below needs a signed-in app user
      if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
      if (path === "/functions/v1/quai-data") {
        const s = session(req);
        if (url.searchParams.get("op") === "upload") {
          const type = String(req.headers["content-type"] ?? "").split(";")[0].trim().toLowerCase();
          const waitIp = uploadIpLimiter.hit(ip);
          if (waitIp > 0) return reply(429, { error: "too_many_uploads", retryAfter: waitIp }, { "Retry-After": String(waitIp), Connection: "close" });
          const limited = s.appRole !== "superuser";
          const waitQuota = limited ? quota.check(s.carrier) : 0;
          if (waitQuota > 0) return reply(429, { error: "upload_quota_exceeded", retryAfter: waitQuota }, { "Retry-After": String(waitQuota), Connection: "close" });
          const bytes = await readBytes(req, MAX_UPLOAD_BYTES);
          if (limited) quota.add(s.carrier, bytes.length); // counted even when the file is then rejected
          const out = await upload({ bucket: url.searchParams.get("bucket") ?? "", path: url.searchParams.get("path") ?? "", type, bytes }, s, store, baseUrl);
          storageAlarm();
          return reply(200, out);
        }
        const body = await readJson(req);
        if (!body || typeof body.op !== "string") throw new HttpError(400, "op_required");
        return reply(200, await run(body.op, body, s, store, baseUrl));
      }
      if (path === "/functions/v1/send-transactional-email") {
        const s = session(req);
        const out = await sendTransactional({
          body: await readJson(req), session: s, store, provider, baseUrl,
          from: config.data.emailFrom, publicSiteUrl: config.data.publicSiteUrl,
        });
        return reply(out.status, out.body);
      }
      throw new HttpError(404, "not_found");
    } catch (e) {
      if (e instanceof HttpError) return reply(e.status, { error: e.code }, e.status === 413 ? { Connection: "close" } : {});
      log("data_error", { path, message: e && e.message });
      return reply(500, { error: "server_error" });
    }
  }

  return { handle, isDataPath };
}
