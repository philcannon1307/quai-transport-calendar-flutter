import { verifySession } from "./jwt.js";

// Provisional picking list source for orders that have no truck yet.
//   GET /middleware/sales-order?id=<salesOrderId>        (digits only)
//   Authorization: Bearer <session JWT>                  (X-Quai-Session accepted too)
// -> GET <MIDDLEWARE_URL>/api/netsuite/sales-orders/<id>          (header fields, exists today)
//    GET <MIDDLEWARE_URL>/api/netsuite/sales-orders/<id>/items    (item lines; NOT built yet, see
//                                                                  output/middleware-items-request.md)
// Roles: logistique and superuser ONLY (carriers are refused). The x-api-key never leaves the server.
// The answer is a small, fixed shape (never the raw NetSuite record). Upstream calls are serialised
// and cached because NetSuite answers 429 CONCURRENCY_LIMIT_EXCEEDED when asked in parallel.

export const SALES_ORDER_PATH = "/middleware/sales-order";
const ALLOWED_ROLES = new Set(["logistique", "superuser"]);
const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
const HEADER_TTL_MS = 5 * 60_000;
const ITEMS_OK_TTL_MS = 60_000;
const ITEMS_MISSING_TTL_MS = 5 * 60_000;
const MAX_ITEMS = 300;

const str = (v, max = 400) => (typeof v === "string" ? v.trim().slice(0, max) : v == null || typeof v === "object" ? "" : String(v).slice(0, max));
const num = (v) => {
  const n = typeof v === "number" ? v : Number(String(v ?? "").replace(",", "."));
  return Number.isFinite(n) ? n : null;
};

/** Upstream sales-order record -> the fixed shape the app consumes. Exported for tests. */
export function mapHeader(up, id) {
  const raw = up && typeof up.raw === "object" && up.raw ? up.raw : {};
  const ref = (v) => (v && typeof v === "object" ? str(v.refName) : str(v));
  return {
    salesOrderId: id,
    soNum: str(up.tranId, 40),
    customer: str(up.entity, 200),
    status: str(up.status, 80),
    orderDate: str(up.tranDate, 20),
    shipDate: str(up.shipDate, 20),
    promiseDate: str(raw.custbody_promisedate, 20),
    location: str(up.location, 80),
    shippingMethod: str(up.shippingMethod, 120),
    address: str(raw.shippingAddress_text || raw.shipAddress, 600),
    city: str(raw.custbody_shipping_city, 120),
    phone: str(raw.custbody_ship_phone, 60),
    eventName: str(raw.custbody_evenement_nom, 200),
    service: ref(raw.custbody_service) || ref(raw.custbodyserviceprecis),
    memo: str(raw.memo, 1000),
  };
}

/** Upstream items answer ({items:[...]} or a bare array) -> [{name,sku,quantity,unit,memo}] or null. */
export function mapItems(body) {
  const list = Array.isArray(body) ? body : body && Array.isArray(body.items) ? body.items : null;
  if (!list) return null;
  return list
    .filter((x) => x && typeof x === "object")
    .slice(0, MAX_ITEMS)
    .map((x) => ({
      name: str(x.name ?? x.itemName ?? x.displayName ?? x.item, 200),
      sku: str(x.sku ?? x.itemId, 80),
      quantity: num(x.quantity),
      unit: str(x.unit ?? x.units, 30),
      memo: str(x.memo ?? x.description, 400),
    }));
}

export function createSalesOrderProxy({ config, limiters, log = () => {}, now = Date.now, retryDelayMs = 1500 }) {
  const base = config.middleware.url;
  const cache = new Map(); // key -> { exp, value }
  const inflight = new Map();
  let chain = Promise.resolve(); // one upstream call at a time

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  function serial(fn) {
    const run = chain.then(fn, fn);
    chain = run.catch(() => {});
    return run;
  }

  /** -> { status, json } ; never throws, never logs the key. */
  async function upstream(path) {
    try {
      const res = await fetch(new URL(base + path), {
        method: "GET",
        headers: { "x-api-key": config.middleware.apiKey, Accept: "application/json" },
        redirect: "error",
        signal: AbortSignal.timeout(config.middleware.timeoutMs),
      });
      const buf = Buffer.from(await res.arrayBuffer());
      if (buf.length > MAX_RESPONSE_BYTES) return { status: 502 };
      let json;
      try { json = JSON.parse(buf.toString("utf8")); } catch { /* not json */ }
      return { status: res.status, json };
    } catch (e) {
      log("sales_order_upstream_error", { kind: e && e.name === "TimeoutError" ? "timeout" : "network" });
      return { status: 502 };
    }
  }

  function cached(key, ttl, load) {
    const hit = cache.get(key);
    if (hit && hit.exp > now()) return Promise.resolve(hit.value);
    if (inflight.has(key)) return inflight.get(key);
    const p = serial(load).then((v) => {
      if (v && v.cache !== false) cache.set(key, { exp: now() + (typeof v.ttl === "number" ? v.ttl : ttl), value: v });
      return v;
    }).finally(() => inflight.delete(key));
    inflight.set(key, p);
    return p;
  }

  const loadHeader = (id) => cached("h" + id, HEADER_TTL_MS, async () => {
    let r = await upstream("/api/netsuite/sales-orders/" + id);
    if (r.status === 502) { await sleep(retryDelayMs); r = await upstream("/api/netsuite/sales-orders/" + id); } // NetSuite 429 surfaces as 502
    if (r.status === 404) return { found: false };
    if (r.status !== 200 || !r.json || typeof r.json !== "object") { log("sales_order_upstream_status", { status: r.status }); return { error: true, cache: false }; }
    return { found: true, header: mapHeader(r.json, id) };
  });

  const loadItems = (id) => cached("i" + id, ITEMS_OK_TTL_MS, async () => {
    const r = await upstream("/api/netsuite/sales-orders/" + id + "/items");
    const items = r.status === 200 ? mapItems(r.json) : null;
    if (items) return { items };
    // 404 = the route does not exist yet -> remember for a while. Anything else (429/5xx) -> try again soon.
    return { items: null, ttl: r.status === 404 ? ITEMS_MISSING_TTL_MS : 15_000 };
  });

  return async function handle(req, url) {
    const m = /^Bearer\s+(\S+)$/i.exec(String(req.headers.authorization ?? ""));
    const x = req.headers["x-quai-session"];
    let claims = null;
    for (const c of [m ? m[1] : null, typeof x === "string" && x ? x : null]) {
      if (!c) continue;
      claims = verifySession(c, config.sessionSecret, now());
      if (claims) break;
    }
    if (!claims) return { status: 401, body: { error: "unauthorized" } };
    if (!ALLOWED_ROLES.has(claims.app_role)) {
      log("sales_order_forbidden", { carrier: claims.carrier, role: claims.app_role });
      return { status: 403, body: { error: "forbidden" } };
    }
    const wait = limiters.middlewarePerSession.hit(String(claims.jti ?? claims.sub));
    if (wait > 0) return { status: 429, body: { error: "too_many_requests", retryAfter: wait }, headers: { "Retry-After": String(wait) } };
    if (!config.middleware.apiKey) return { status: 503, body: { error: "middleware_not_configured" } };

    const q = url.searchParams;
    for (const k of q.keys()) if (k !== "id" && k !== "_") return { status: 400, body: { error: "bad_request", field: k } };
    const id = q.get("id") ?? "";
    if (!/^\d{1,12}$/.test(id)) return { status: 400, body: { error: "bad_request", field: "id" } };

    const h = await loadHeader(id);
    if (h.error) return { status: 502, body: { error: "upstream_unavailable" } };
    if (!h.found) return { status: 404, body: { error: "not_found" } };
    const it = await loadItems(id);
    return {
      status: 200,
      body: { provisional: true, ...h.header, items: it.items, itemsAvailable: Array.isArray(it.items) },
    };
  };
}
