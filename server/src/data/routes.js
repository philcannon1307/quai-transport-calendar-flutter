// HTTP surface of the data API. The paths deliberately mirror the Supabase ones the Flutter app already
// calls, so moving over is a configuration change (QUAI_BACKEND_URL), not a code change:
//   POST /functions/v1/quai-data                    JSON {op, ...}  or  ?op=upload&bucket=&path= with the raw picture
//   POST /functions/v1/send-transactional-email
//   GET|POST /functions/v1/handle-email-unsubscribe
//   GET  /rest/v1/announcements | /rest/v1/announcement_images     (public read of active announcements)
//   GET  /storage/v1/object/public/<bucket>/<path>                  (public pictures)
import { RateLimiter } from "../limiter.js";
import { encodePath, isUuid, sessionFromToken, sessionTokenFrom } from "./guard.js";
import { HttpError, MAX_JSON_BYTES, MAX_UPLOAD_BYTES, run, upload } from "./handler.js";
import { handleUnsubscribe, sendTransactional } from "./email.js";

const PUBLIC_BUCKETS = new Set(["announcement-images", "receipts"]);
const CORS = {
  "Access-Control-Allow-Origin": "*", // auth is a bearer token, never a cookie
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-quai-session, x-supabase-api-version",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Max-Age": "600",
};

export function isDataPath(path) {
  return path.startsWith("/functions/v1/") || path.startsWith("/rest/v1/") || path.startsWith("/storage/v1/object/public/");
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

  function send(res, status, body, extra = {}) {
    res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...CORS, ...extra });
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
    try {
      if (req.method === "OPTIONS") return send(res, 204, undefined);
      if (!store) throw new HttpError(503, "data_not_configured");
      const wait = limiter.hit(ip);
      if (wait > 0) return send(res, 429, { error: "too_many_requests", retryAfter: wait }, { "Retry-After": String(wait) });

      // ---- public reads
      if (req.method === "GET" && path === "/rest/v1/announcements") {
        return send(res, 200, await store.listActiveAnnouncements());
      }
      if (req.method === "GET" && path === "/rest/v1/announcement_images") {
        const m = /^in\.\((.*)\)$/.exec(url.searchParams.get("announcement_id") ?? "");
        const ids = m ? m[1].split(",").map((x) => x.trim()).filter(isUuid).slice(0, 200) : [];
        return send(res, 200, await store.listAnnouncementImages(ids));
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
          "X-Content-Type-Options": "nosniff", "Content-Security-Policy": "default-src 'none'; sandbox", ...CORS,
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
        return send(res, out.status, out.body);
      }

      // ---- everything below needs a signed-in app user
      if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
      if (path === "/functions/v1/quai-data") {
        const s = session(req);
        if (url.searchParams.get("op") === "upload") {
          const type = String(req.headers["content-type"] ?? "").split(";")[0].trim().toLowerCase();
          const bytes = await readBytes(req, MAX_UPLOAD_BYTES);
          const out = await upload({ bucket: url.searchParams.get("bucket") ?? "", path: url.searchParams.get("path") ?? "", type, bytes }, s, store, baseUrl);
          return send(res, 200, out);
        }
        const body = await readJson(req);
        if (!body || typeof body.op !== "string") throw new HttpError(400, "op_required");
        return send(res, 200, await run(body.op, body, s, store, baseUrl));
      }
      if (path === "/functions/v1/send-transactional-email") {
        const s = session(req);
        const out = await sendTransactional({
          body: await readJson(req), session: s, store, provider, baseUrl,
          from: config.data.emailFrom, publicSiteUrl: config.data.publicSiteUrl,
        });
        return send(res, out.status, out.body);
      }
      throw new HttpError(404, "not_found");
    } catch (e) {
      if (e instanceof HttpError) return send(res, e.status, { error: e.code }, e.status === 413 ? { Connection: "close" } : {});
      log("data_error", { path, message: e && e.message });
      return send(res, 500, { error: "server_error" });
    }
  }

  return { handle, isDataPath };
}
