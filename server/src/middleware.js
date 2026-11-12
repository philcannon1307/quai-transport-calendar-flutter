import { verifySession } from "./jwt.js";

// Pick-ups proxy for the SADM - Logistique dispatcher view.
//   GET /middleware/events?[location=<name>&]from=YYYY-MM-DD&to=YYYY-MM-DD
//   Authorization: Bearer <session JWT>   (X-Quai-Session is accepted too)
// -> GET <MIDDLEWARE_URL>/api/netsuite/events with the x-api-key from MIDDLEWARE_API_KEY.
//
// Allow-list: this ONE upstream endpoint, GET only, and only the three query parameters below, each
// validated. Nothing from the caller is forwarded as a header or as a path. The key is never logged,
// never returned and never put in an error.

export const MIDDLEWARE_PATH = "/middleware/events";
const UPSTREAM_PATH = "/api/netsuite/events";
const ALLOWED_ROLES = new Set(["logistique", "superuser"]);
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
const MAX_RANGE_DAYS = 120;

const DAY = /^\d{4}-\d{2}-\d{2}$/;
function parseDay(s) {
  if (typeof s !== "string" || !DAY.test(s)) return null;
  const t = Date.parse(s + "T00:00:00Z");
  return Number.isNaN(t) || new Date(t).toISOString().slice(0, 10) !== s ? null : t;
}

/** Candidate tokens: the Authorization bearer, then X-Quai-Session. */
function tokenOf(req) {
  const m = /^Bearer\s+(\S+)$/i.exec(String(req.headers.authorization ?? ""));
  const x = req.headers["x-quai-session"];
  return { bearer: m ? m[1] : null, session: typeof x === "string" && x ? x : null };
}

export function createMiddlewareProxy({ config, limiters, log = () => {}, now = Date.now }) {
  const base = config.middleware.url;

  /** -> { status, body, headers? } ; the caller adds CORS. */
  return async function handle(req, url, ip) {
    const t = tokenOf(req);
    // The Authorization bearer is tried first, then X-Quai-Session (the app sends both).
    let claims = null;
    for (const c of [t.bearer, t.session]) {
      if (!c) continue;
      claims = verifySession(c, config.sessionSecret, now());
      if (claims) break;
    }
    if (!claims) return { status: 401, body: { error: "unauthorized" } };
    if (!ALLOWED_ROLES.has(claims.app_role)) {
      log("middleware_forbidden", { carrier: claims.carrier, role: claims.app_role });
      return { status: 403, body: { error: "forbidden" } };
    }
    // 60 / minute per session (jti), plus the per-IP limit applied by the caller.
    const wait = limiters.middlewarePerSession.hit(String(claims.jti ?? claims.sub));
    if (wait > 0) return { status: 429, body: { error: "too_many_requests", retryAfter: wait }, headers: { "Retry-After": String(wait) } };

    if (!config.middleware.apiKey) {
      log("middleware_not_configured");
      return { status: 503, body: { error: "middleware_not_configured" } };
    }

    const q = url.searchParams;
    const allowedParams = new Set(["location", "from", "to", "_"]);
    for (const k of q.keys()) if (!allowedParams.has(k)) return { status: 400, body: { error: "bad_request", field: k } };
    // location is OPTIONAL: absent = every location (the middleware then returns all of them in one
    // call). When present it is still validated exactly as before (1-60 chars, no control chars).
    const hasLocation = q.has("location");
    const location = (q.get("location") ?? "").trim();
    if (hasLocation && (!location || location.length > 60 || /[\u0000-\u001f]/.test(location))) return { status: 400, body: { error: "bad_request", field: "location" } };
    const from = parseDay(q.get("from"));
    const to = parseDay(q.get("to"));
    if (from === null) return { status: 400, body: { error: "bad_request", field: "from" } };
    if (to === null) return { status: 400, body: { error: "bad_request", field: "to" } };
    if (to < from || (to - from) / 86400000 > MAX_RANGE_DAYS) return { status: 400, body: { error: "bad_request", field: "range" } };

    const target = new URL(base + UPSTREAM_PATH);
    if (hasLocation) target.searchParams.set("location", location);
    target.searchParams.set("from", q.get("from"));
    target.searchParams.set("to", q.get("to"));

    let res;
    try {
      res = await fetch(target, {
        method: "GET",
        headers: { "x-api-key": config.middleware.apiKey, Accept: "application/json" },
        redirect: "error", // never follow a redirect with the key attached
        signal: AbortSignal.timeout(config.middleware.timeoutMs),
      });
      if (!res.ok) {
        log("middleware_upstream_status", { status: res.status });
        return { status: 502, body: { error: "upstream_unavailable" } };
      }
      const buf = Buffer.from(await res.arrayBuffer());
      if (buf.length > MAX_RESPONSE_BYTES) {
        log("middleware_upstream_too_large", { bytes: buf.length });
        return { status: 502, body: { error: "upstream_unavailable" } };
      }
      const text = buf.toString("utf8");
      try { JSON.parse(text); } catch {
        log("middleware_upstream_not_json");
        return { status: 502, body: { error: "upstream_unavailable" } };
      }
      return { raw: text, status: 200 };
    } catch (e) {
      // e.name only: an error message could carry the URL.
      log("middleware_upstream_error", { kind: e && e.name === "TimeoutError" ? "timeout" : "network" });
      return { status: 502, body: { error: "upstream_unavailable" } };
    }
  };
}
