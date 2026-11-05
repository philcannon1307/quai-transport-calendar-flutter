import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { startApp, ORIGIN, SECRET } from "./helpers.js";
import { signSession } from "../src/jwt.js";
import { mapHeader, mapItems } from "../src/salesOrder.js";

const KEY = "UPSTREAM-SECRET-KEY-do-not-leak";
const SO = {
  id: "268333", tranId: "SO20448", entity: "17208 Dominic Deroy", customerId: "18767", status: "Pending Fulfillment",
  tranDate: "2026-10-30", shipDate: "2026-11-04", amount: 0, shippingMethod: "Livraison", location: "Ste-Agathe",
  raw: {
    shippingAddress_text: "Dominic Deroy\n12 rue X\nSaint-Donat", custbody_shipping_city: "Saint-Donat", custbody_ship_phone: "+15145550000",
    custbody_evenement_nom: "Mariage", custbody_promisedate: "2026-11-04", memo: "Appeler avant", email: "secret@example.com",
    custbody_service: { id: "1", refName: "Installation" },
  },
};

/** Stand-in for quai-backend-methods. itemsMode: 404 | ok | bare | 429 */
async function startUpstream({ header = "ok", itemsMode = "404" } = {}) {
  const calls = [];
  let active = 0, maxActive = 0, headerHits = 0;
  const server = http.createServer((req, res) => {
    calls.push({ url: req.url, key: req.headers["x-api-key"], auth: req.headers.authorization });
    active++; maxActive = Math.max(maxActive, active);
    const done = (status, body) => setTimeout(() => { active--; res.writeHead(status, { "Content-Type": "application/json" }).end(JSON.stringify(body)); }, 20);
    const m = /^\/api\/netsuite\/sales-orders\/(\d+)(\/items)?$/.exec(req.url);
    if (!m) return done(404, { error: "Not found" });
    if (m[2]) {
      if (itemsMode === "ok") return done(200, { items: [{ name: "Quai 8x20", sku: "Q-820", quantity: 3, unit: "ea", memo: "M", secretField: KEY }] });
      if (itemsMode === "bare") return done(200, [{ itemName: "Rampe", quantity: "2" }]);
      if (itemsMode === "429") return done(502, { error: "NetSuite error" });
      return done(404, { error: "Not found" });
    }
    if (m[1] === "999") return done(404, { error: "Not found" });
    headerHits++;
    if (header === "flaky" && headerHits === 1) return done(502, { error: "NetSuite error", detail: "429" });
    if (header === "down") return done(500, { error: "x " + KEY });
    done(200, SO);
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { url: "http://127.0.0.1:" + server.address().port, calls, stats: () => ({ maxActive, headerHits }), close: () => { server.closeAllConnections?.(); return new Promise((r) => server.close(r)); } };
}

const tok = (appRole, carrier = "SADM - Logistique", secret = SECRET) => signSession({ carrier, appRole, trucks: [], names: [] }, secret, 600, Date.now()).token;
const bearer = (t) => ({ Authorization: "Bearer " + t });
async function withProxy(opts, fn, env = {}) {
  const up = await startUpstream(opts);
  const app = await startApp({ env: { MIDDLEWARE_URL: up.url, MIDDLEWARE_API_KEY: KEY, MIDDLEWARE_TIMEOUT_MS: "1500", ...env } });
  try { await fn(app, up); } finally { await app.close(); await up.close(); }
}
const get = (app, qs, headers, opts = {}) => app.call(undefined, { method: "GET", path: "/middleware/sales-order" + qs, headers, ...opts });

test("logistique gets the provisional header, no items yet, key added upstream, no raw/email leaked", async () => {
  await withProxy({}, async (app, up) => {
    const r = await get(app, "?id=268333&_=1", bearer(tok("logistique")));
    assert.equal(r.status, 200);
    assert.equal(r.json.provisional, true);
    assert.equal(r.json.soNum, "SO20448");
    assert.equal(r.json.customer, "17208 Dominic Deroy");
    assert.equal(r.json.status, "Pending Fulfillment");
    assert.equal(r.json.phone, "+15145550000");
    assert.equal(r.json.city, "Saint-Donat");
    assert.equal(r.json.service, "Installation");
    assert.equal(r.json.memo, "Appeler avant");
    assert.equal(r.json.items, null);
    assert.equal(r.json.itemsAvailable, false);
    assert.ok(!r.text.includes("secret@example.com") && !r.text.includes(KEY) && !r.text.includes("raw"));
    assert.equal(r.headers.get("access-control-allow-origin"), ORIGIN);
    assert.ok(up.calls.every((c) => c.key === KEY && c.auth === undefined));
    assert.deepEqual(up.calls.map((c) => c.url), ["/api/netsuite/sales-orders/268333", "/api/netsuite/sales-orders/268333/items"]);
  });
});

test("items appear as soon as the middleware route exists (object and bare-array shapes), unknown fields dropped", async () => {
  await withProxy({ itemsMode: "ok" }, async (app) => {
    const r = await get(app, "?id=268333", bearer(tok("superuser", "SuperUser")));
    assert.equal(r.status, 200);
    assert.equal(r.json.itemsAvailable, true);
    assert.deepEqual(r.json.items, [{ name: "Quai 8x20", sku: "Q-820", quantity: 3, unit: "ea", memo: "M" }]);
    assert.ok(!r.text.includes(KEY));
  });
  assert.deepEqual(mapItems([{ itemName: "Rampe", quantity: "2" }]), [{ name: "Rampe", sku: "", quantity: 2, unit: "", memo: "" }]);
  assert.equal(mapItems({ nope: 1 }), null);
  assert.equal(mapHeader({ tranId: "SO1" }, "1").soNum, "SO1");
});

test("carriers, anonymous, bad token are refused and never reach upstream", async () => {
  await withProxy({}, async (app, up) => {
    assert.equal((await get(app, "?id=268333", bearer(tok("carrier", "Gat - Sam")))).status, 403);
    assert.equal((await get(app, "?id=268333", {})).status, 401);
    assert.equal((await get(app, "?id=268333", bearer("not.a.jwt"))).status, 401);
    assert.equal((await get(app, "?id=268333", bearer(tok("logistique", "SADM - Logistique", "x".repeat(40))))).status, 401);
    assert.equal(up.calls.length, 0);
  });
});

test("input is validated: digits only id, no extra params, GET only, origin allow-list", async () => {
  await withProxy({}, async (app, up) => {
    const h = bearer(tok("logistique"));
    for (const qs of ["", "?id=", "?id=abc", "?id=1/2", "?id=../x", "?id=123456789012345", "?id=1%0d%0a", "?id=268333&path=/x"]) {
      assert.equal((await get(app, qs, h)).status, 400, qs);
    }
    assert.equal(up.calls.length, 0);
    assert.equal((await app.call({}, { method: "POST", path: "/middleware/sales-order?id=1", headers: h })).status, 405);
    assert.equal((await get(app, "?id=268333", h, { origin: "https://evil.example" })).status, 403);
  });
});

test("unknown order -> 404; upstream down -> 502 without leaking the key", async () => {
  await withProxy({}, async (app) => {
    assert.equal((await get(app, "?id=999", bearer(tok("logistique")))).status, 404);
  });
  await withProxy({ header: "down" }, async (app) => {
    const r = await get(app, "?id=268333", bearer(tok("logistique")));
    assert.equal(r.status, 502);
    assert.ok(!r.text.includes(KEY));
  });
});

test("a NetSuite 429 (surfaced as 502) is retried once; repeated asks are cached and upstream calls never overlap", async () => {
  await withProxy({ header: "flaky" }, async (app, up) => {
    const h = bearer(tok("logistique"));
    const r = await get(app, "?id=268333", h);
    assert.equal(r.status, 200);
    const before = up.calls.length;
    const rs = await Promise.all([get(app, "?id=268333", h), get(app, "?id=268333", h), get(app, "?id=268333", h)]);
    assert.ok(rs.every((x) => x.status === 200));
    assert.equal(up.calls.length, before, "served from cache");
    assert.equal(up.stats().maxActive, 1, "serialised");
  });
});
