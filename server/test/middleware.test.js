import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { startApp, ORIGIN, SECRET } from "./helpers.js";
import { signSession } from "../src/jwt.js";

const KEY = "UPSTREAM-SECRET-KEY-do-not-leak";
const Q = "?location=Ste-Agathe&from=2026-11-01&to=2026-11-07";
const EVENTS = { events: [{ id: "1", title: "SADM - Ste-Agathe / SO100 / Client / Ramassage", salesOrderId: "100", startDate: "2026-11-03" }] };

/** Stand-in for quai-backend-methods. mode: ok | 500 | html | hang | big | redirect */
async function startUpstream(mode = "ok") {
  const calls = [];
  const server = http.createServer((req, res) => {
    calls.push({ method: req.method, url: req.url, key: req.headers["x-api-key"], auth: req.headers.authorization, session: req.headers["x-quai-session"], cookie: req.headers.cookie });
    if (mode === "hang") return; // never answers
    if (mode === "500") { res.writeHead(500, { "Content-Type": "text/plain" }).end("boom " + KEY); return; }
    if (mode === "html") { res.writeHead(200, { "Content-Type": "text/html" }).end("<html>login</html>"); return; }
    if (mode === "big") { res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ events: [], pad: "x".repeat(5 * 1024 * 1024) })); return; }
    if (mode === "redirect") { res.writeHead(302, { Location: "http://127.0.0.1:1/steal" }).end(); return; }
    res.writeHead(200, { "Content-Type": "application/json", "Set-Cookie": "up=1", "x-upstream-secret": KEY }).end(JSON.stringify(EVENTS));
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { url: "http://127.0.0.1:" + server.address().port, calls, close: () => { server.closeAllConnections?.(); return new Promise((r) => server.close(r)); } };
}

const tok = (appRole, carrier = "SADM - Logistique", secret = SECRET, ttl = 600, now = Date.now()) =>
  signSession({ carrier, appRole, trucks: [], names: [] }, secret, ttl, now).token;
const bearer = (t) => ({ Authorization: "Bearer " + t });

async function withProxy(mode, fn, env = {}) {
  const up = await startUpstream(mode);
  const app = await startApp({ env: { MIDDLEWARE_URL: up.url, MIDDLEWARE_API_KEY: KEY, MIDDLEWARE_TIMEOUT_MS: "1500", ...env } });
  try { await fn(app, up); } finally { await app.close(); await up.close(); }
}
const get = (app, qs, headers, opts = {}) => app.call(undefined, { method: "GET", path: "/middleware/events" + qs, headers, ...opts });

test("logistique: forwards ONLY the allowed query, adds x-api-key, returns the JSON unchanged", async () => {
  await withProxy("ok", async (app, up) => {
    const r = await get(app, Q + "&_=12345", bearer(tok("logistique")));
    assert.equal(r.status, 200);
    assert.deepEqual(r.json, EVENTS);
    assert.equal(r.headers.get("access-control-allow-origin"), ORIGIN);
    assert.equal(r.headers.get("set-cookie"), null, "upstream headers are not passed on");
    assert.equal(r.headers.get("x-upstream-secret"), null);
    assert.equal(up.calls.length, 1);
    const c = up.calls[0];
    assert.equal(c.method, "GET");
    assert.equal(c.key, KEY);
    assert.equal(c.url, "/api/netsuite/events?location=Ste-Agathe&from=2026-11-01&to=2026-11-07", "cache-buster and anything else is dropped");
    assert.equal(c.auth, undefined, "the caller's session token never reaches the middleware");
    assert.equal(c.session, undefined);
    assert.equal(c.cookie, undefined);
    assert.ok(!r.text.includes(KEY));
  });
});

test("location is optional: absent = all locations, nothing else changes", async () => {
  await withProxy("ok", async (app, up) => {
    const r = await get(app, "?from=2026-11-01&to=2026-11-07", bearer(tok("logistique")));
    assert.equal(r.status, 200);
    assert.equal(up.calls[0].url, "/api/netsuite/events?from=2026-11-01&to=2026-11-07");
    assert.equal(up.calls[0].key, KEY);
    const bad = await get(app, "?location=&from=2026-11-01&to=2026-11-07", bearer(tok("logistique")));
    assert.equal(bad.status, 400, "an explicitly empty location is still refused");
    const unk = await get(app, "?from=2026-11-01&to=2026-11-07&evil=1", bearer(tok("logistique")));
    assert.equal(unk.status, 400);
    const forb = await get(app, "?from=2026-11-01&to=2026-11-07", bearer(tok("carrier", "Some - Truck")));
    assert.ok([401, 403].includes(forb.status));
  });
});

test("superuser is allowed; X-Quai-Session alone also works", async () => {
  await withProxy("ok", async (app) => {
    assert.equal((await get(app, Q, bearer(tok("superuser", "SuperUser")))).status, 200);
    assert.equal((await get(app, Q, { "X-Quai-Session": tok("logistique") })).status, 200);
  });
});

test("carriers, missing / garbage / expired / wrong-secret / publishable-key tokens are refused and never reach upstream", async () => {
  await withProxy("ok", async (app, up) => {
    assert.equal((await get(app, Q, bearer(tok("carrier", "Gat - Sam")))).status, 403);
    assert.equal((await get(app, Q, {})).status, 401);
    assert.equal((await get(app, Q, bearer("not.a.jwt"))).status, 401);
    assert.equal((await get(app, Q, bearer("eyJhbGciOiJub25lIn0.eyJhcHBfcm9sZSI6InN1cGVydXNlciJ9."))).status, 401, "alg none");
    assert.equal((await get(app, Q, bearer(tok("logistique", "x", SECRET, 60, Date.now() - 3600_000)))).status, 401, "expired");
    assert.equal((await get(app, Q, bearer(tok("logistique", "x", "another-secret-another-secret-another-1")))).status, 401);
    assert.equal(up.calls.length, 0);
  });
});

test("only GET on this path; POST/PUT/DELETE are 405; unknown sub-paths are 404", async () => {
  await withProxy("ok", async (app, up) => {
    for (const method of ["POST", "PUT", "DELETE", "PATCH"]) {
      const r = await app.call({}, { method, path: "/middleware/events" + Q, headers: bearer(tok("logistique")) });
      assert.equal(r.status, 405, method);
    }
    assert.equal((await get(app, "", bearer(tok("logistique")), {})).status, 400);
    const other = await app.call(undefined, { method: "GET", path: "/middleware/other", headers: bearer(tok("logistique")) });
    assert.equal(other.status, 404);
    const trav = await app.call(undefined, { method: "GET", path: "/middleware/events/../../api/secret", headers: bearer(tok("logistique")) });
    assert.equal(trav.status, 404);
    assert.equal(up.calls.length, 0);
  });
});

test("input is validated: unknown params, bad dates, long range, empty/oversized location", async () => {
  await withProxy("ok", async (app, up) => {
    const h = bearer(tok("logistique"));
    for (const qs of [
      Q + "&x=1",
      "?location=Ste-Agathe&from=2026-13-01&to=2026-11-07",
      "?location=Ste-Agathe&from=2026-11-01T00:00:00Z&to=2026-11-07",
      "?location=Ste-Agathe&from=2026-11-07&to=2026-11-01",
      "?location=Ste-Agathe&from=2026-01-01&to=2026-12-31",
      "?location=&from=2026-11-01&to=2026-11-07",
      "?location=" + "a".repeat(61) + "&from=2026-11-01&to=2026-11-07",
    ]) assert.equal((await get(app, qs, h)).status, 400, qs);
    assert.equal(up.calls.length, 0);
    // a location that tries to inject a query parameter is encoded, not interpreted
    const r = await get(app, "?location=Ste-Agathe%26from%3D1999-01-01&from=2026-11-01&to=2026-11-07", h);
    assert.equal(r.status, 200);
    assert.equal(up.calls[0].url, "/api/netsuite/events?location=Ste-Agathe%26from%3D1999-01-01&from=2026-11-01&to=2026-11-07");
  });
});

test("upstream failures are 502 with a fixed body: 500, non-JSON, too large, redirect, hang, down", async () => {
  for (const mode of ["500", "html", "big", "redirect", "hang"]) {
    await withProxy(mode, async (app) => {
      const r = await get(app, Q, bearer(tok("logistique")));
      assert.equal(r.status, 502, mode);
      assert.deepEqual(r.json, { error: "upstream_unavailable" }, mode);
      assert.ok(!r.text.includes(KEY) && !r.text.includes("boom"), mode);
    });
  }
  const app = await startApp({ env: { MIDDLEWARE_URL: "http://127.0.0.1:1", MIDDLEWARE_API_KEY: KEY } });
  try {
    const r = await get(app, Q, bearer(tok("logistique")));
    assert.equal(r.status, 502);
    assert.ok(!JSON.stringify(app.logs).includes(KEY), "the key is never logged");
  } finally { await app.close(); }
});

test("no MIDDLEWARE_API_KEY: 503, nothing is forwarded; the server still starts", async () => {
  await withProxy("ok", async (app, up) => {
    const r = await get(app, Q, bearer(tok("logistique")));
    assert.equal(r.status, 503);
    assert.deepEqual(r.json, { error: "middleware_not_configured" });
    assert.equal(up.calls.length, 0);
  }, { MIDDLEWARE_API_KEY: "" });
});

test("CORS: exact origin only; preflight allows GET + the headers the app sends", async () => {
  await withProxy("ok", async (app, up) => {
    const bad = await get(app, Q, bearer(tok("logistique")), { origin: "https://evil.example.com" });
    assert.equal(bad.status, 403);
    const sub = await get(app, Q, bearer(tok("logistique")), { origin: ORIGIN + ".evil.com" });
    assert.equal(sub.status, 403);
    assert.equal(up.calls.length, 0);
    const pre = await app.call(undefined, { method: "OPTIONS", path: "/middleware/events", headers: { "Access-Control-Request-Method": "GET" } });
    assert.equal(pre.status, 204);
    assert.equal(pre.headers.get("access-control-allow-origin"), ORIGIN);
    assert.equal(pre.headers.get("access-control-allow-methods"), "GET, OPTIONS");
    const allowed = pre.headers.get("access-control-allow-headers").toLowerCase();
    for (const h of ["authorization", "x-quai-session", "cache-control"]) assert.ok(allowed.includes(h), h);
    const noOrigin = await get(app, Q, bearer(tok("logistique")), { origin: "" });
    assert.equal(noOrigin.status, 200, "a non-browser caller has no Origin");
  });
});

test("rate limit: 60 requests/minute per session, then 429 with Retry-After; another session is unaffected", async () => {
  await withProxy("ok", async (app, up) => {
    const h = bearer(tok("logistique"));
    // spread over fake client IPs so the per-IP limit does not interfere
    for (let i = 0; i < 60; i++) assert.equal((await get(app, Q, h, { ip: "10.9." + Math.floor(i / 100) + "." + i })).status, 200, "request " + i);
    const r = await get(app, Q, h, { ip: "10.9.9.9" });
    assert.equal(r.status, 429);
    assert.ok(Number(r.headers.get("retry-after")) >= 1);
    assert.equal(up.calls.length, 60);
    assert.equal((await get(app, Q, bearer(tok("superuser", "SuperUser")), { ip: "10.9.9.10" })).status, 200);
  });
});

test("rate limit per IP: 120/minute even with fresh sessions", async () => {
  await withProxy("ok", async (app) => {
    let last = 0;
    for (let i = 0; i < 121; i++) last = (await get(app, Q, bearer(tok("logistique", "L" + i)), { ip: "10.8.8.8" })).status;
    assert.equal(last, 429);
  });
});
