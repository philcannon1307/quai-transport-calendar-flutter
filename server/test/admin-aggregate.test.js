import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { makeConfig, ORIGIN, SECRET } from "./helpers.js";
import { createApp } from "../src/app.js";
import { createJobService } from "../src/jobService.js";
import { createAdminAggregate } from "../src/adminAggregate.js";
import { allAccounts, CARRIERS } from "../src/roster.js";
import { signSession } from "../src/jwt.js";
import { MemoryStore } from "../src/data/store-memory.js";

const PW = (u) => "pw-" + u + "-SECRET";
const names = [...new Set([...CARRIERS.map((c) => c.displayName), ...allAccounts().map((a) => a.username)])];
const CREDS = Object.fromEntries(names.map((n) => [n, { code: "123456", password: PW(n) }]));
const row = (u, i, extra = {}) => ({ salesOrderId: 1000 + i, soNum: "SO" + u.length + i, customer: "Client " + u, ...extra });

/** Stand-in for the job service: serves ONE request at a time check, per-user data and failures. */
async function startJobs({ fail = {}, hang = new Set(), expire = new Set() } = {}) {
  const st = { active: 0, maxActive: 0, calls: [], logins: [] };
  const server = http.createServer((req, res) => {
    st.active += 1; st.maxActive = Math.max(st.maxActive, st.active);
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", async () => {
      const done = () => { st.active -= 1; };
      const path = req.url.split("?")[0];
      if (path === "/api/auth/mvp-login") {
        const { username, password } = JSON.parse(body || "{}");
        st.logins.push(username);
        await new Promise((r) => setTimeout(r, 2));
        done();
        if (password !== PW(username)) return res.writeHead(401).end("{}");
        return res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ accessToken: "tok:" + username }));
      }
      const user = String(req.headers.authorization ?? "").replace("Bearer tok:", "");
      st.calls.push({ path, user });
      await new Promise((r) => setTimeout(r, 2));
      if (hang.has(user)) { done(); return; }
      if (expire.has(user)) { expire.delete(user); done(); return res.writeHead(401).end("{}"); }
      const f = fail[user];
      if (f === 500 || (typeof f === "function" && f())) { done(); return res.writeHead(500).end("boom"); }
      done();
      if (path === "/api/ship-calendar/orders") return res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ orders: [row(user, 1), row(user, 2)] }));
      if (path === "/api/transfer-calendar/orders") return res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ orders: [row(user, 9, { toNum: "TO1" }), row(user, 8, { isShell: true })] }));
      res.writeHead(404).end("{}");
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { url: "http://127.0.0.1:" + server.address().port, st, close: () => { server.closeAllConnections?.(); return new Promise((r) => server.close(r)); } };
}

function build(jobsStub, { env = {}, store = null, logs = [] } = {}) {
  const config = makeConfig({
    CARRIER_CREDENTIALS_JSON: JSON.stringify(CREDS),
    JOB_SERVICE_URL: jobsStub.url,
    ADMIN_AGGREGATE_REFRESH_SECONDS: "30",
    ...env,
  });
  const log = (e, f) => logs.push({ e, ...f });
  const jobs = createJobService({ baseUrl: config.jobServiceUrl, timeoutMs: 5000 });
  const agg = createAdminAggregate({ config, jobs, store, log, retryDelayMs: 0, sleepImpl: async () => {} });
  return { config, agg, log, jobs, logs };
}

const tok = (appRole, carrier = "SADM - Logistique") => signSession({ carrier, appRole, trucks: [], names: [] }, SECRET, 600).token;

test("covers every truck (19), strictly one request at a time, with transfers only for Gooseneck", async () => {
  const jobsStub = await startJobs();
  try {
    const { agg } = build(jobsStub);
    assert.equal(agg.accounts.length, 19);
    await agg.refreshNow("test");
    assert.equal(jobsStub.st.maxActive, 1, "the job service must never see two requests at once");
    const snap = agg.snapshot();
    assert.equal(snap.trucks.length, 19);
    assert.ok(snap.trucks.every((x) => x.ok && x.status === "ok" && x.lastRefreshedAt));
    assert.ok(snap.generatedAt);
    const rideau = snap.trucks.find((x) => x.name === "RIDEAU GOOSENECK");
    assert.equal(rideau.orders.ship.length, 2);
    assert.equal(rideau.orders.transfer.length, 1, "shell transfer rows are dropped");
    assert.equal(rideau.orders.transfer[0].toNum, "TO1");
    assert.equal(snap.trucks.find((x) => x.name === "Gat - Sam").orders.transfer.length, 0);
    assert.equal(jobsStub.st.calls.filter((c) => c.path === "/api/transfer-calendar/orders").length, 2);
    assert.equal(snap.trucks.find((x) => x.name === "InterQL"), undefined, "InterQL is represented by its two trucks");
    assert.equal(snap.trucks.find((x) => x.name === "SADM - Éric").displayName, "SADM - Éric");
  } finally { await jobsStub.close(); }
});

test("a cycle never overlaps itself: a second refresh joins the one in flight", async () => {
  const jobsStub = await startJobs();
  try {
    const { agg } = build(jobsStub);
    const a = agg.refreshNow("a");
    const b = agg.refreshNow("b");
    assert.equal(a, b);
    assert.equal(agg.snapshot().refreshing, true);
    await a;
    assert.equal(agg.snapshot().refreshing, false);
    assert.equal(jobsStub.st.maxActive, 1);
    assert.equal(jobsStub.st.calls.filter((c) => c.user === "Gat - Sam").length, 1);
  } finally { await jobsStub.close(); }
});

test("a failing truck is reported failed, a later failure keeps the old data as stale; others are unaffected", async () => {
  let down = false;
  const jobsStub = await startJobs({ fail: { "Québec - Marc": 500, "Gat - Sam": () => down } });
  try {
    const { agg, logs } = build(jobsStub);
    await agg.refreshNow("1");
    let snap = agg.snapshot();
    const marc = snap.trucks.find((x) => x.name === "Québec - Marc");
    assert.equal(marc.ok, false);
    assert.equal(marc.status, "failed");
    assert.equal(marc.lastRefreshedAt, null);
    assert.deepEqual(marc.orders, { ship: [], transfer: [] });
    assert.equal(snap.trucks.filter((x) => x.ok).length, 18);
    assert.equal(snap.trucks.find((x) => x.name === "Gat - Sam").status, "ok");
    down = true;
    await agg.refreshNow("2");
    snap = agg.snapshot();
    const sam = snap.trucks.find((x) => x.name === "Gat - Sam");
    assert.equal(sam.status, "stale");
    assert.equal(sam.ok, false);
    assert.ok(sam.lastRefreshedAt, "the last good time is kept");
    assert.equal(sam.orders.ship.length, 2, "the last good orders are kept");
    assert.ok(logs.some((l) => l.e === "admin_aggregate_truck_failed" && l.truck === "Québec - Marc"));
  } finally { await jobsStub.close(); }
});

test("an expired job-service token is renewed once and the truck still loads", async () => {
  const jobsStub = await startJobs({ expire: new Set(["SADM - Steve"]) });
  try {
    const { agg } = build(jobsStub);
    await agg.refreshNow("1");
    const steve = agg.snapshot().trucks.find((x) => x.name === "SADM - Steve");
    assert.equal(steve.ok, true);
    assert.equal(jobsStub.st.logins.filter((u) => u === "SADM - Steve").length, 2, "logged in again after the 401");
  } finally { await jobsStub.close(); }
});

test("a hanging truck times out (per-truck timeout) and does not block the rest", async () => {
  const jobsStub = await startJobs({ hang: new Set(["Lindsay - Cole"]) });
  try {
    const { agg } = build(jobsStub, { env: { ADMIN_AGGREGATE_TRUCK_TIMEOUT_MS: "1000" } });
    await agg.refreshNow("1");
    const snap = agg.snapshot();
    assert.equal(snap.trucks.find((x) => x.name === "Lindsay - Cole").status, "failed");
    assert.equal(snap.trucks.filter((x) => x.ok).length, 18);
  } finally { await jobsStub.close(); }
});

test("carrier names match without accents or case in CARRIER_CREDENTIALS_JSON", async () => {
  const jobsStub = await startJobs();
  try {
    const creds = { ...CREDS };
    delete creds["SADM - Éric"]; delete creds["Québec - Marc"];
    creds["sadm - eric"] = { code: "123456", password: PW("SADM - Éric") };
    creds["Quebec - Marc"] = { code: "123456", password: PW("Québec - Marc") };
    const { agg } = build(jobsStub, { env: { CARRIER_CREDENTIALS_JSON: JSON.stringify(creds) } });
    await agg.refreshNow("1");
    const snap = agg.snapshot();
    assert.equal(snap.trucks.find((x) => x.name === "SADM - Éric").ok, true);
    assert.equal(snap.trucks.find((x) => x.name === "Québec - Marc").ok, true);
  } finally { await jobsStub.close(); }
});

test("a truck without credentials is failed, not an error", async () => {
  const jobsStub = await startJobs();
  try {
    const creds = { ...CREDS };
    delete creds["DA TRANSPORT"];
    const { agg } = build(jobsStub, { env: { CARRIER_CREDENTIALS_JSON: JSON.stringify(creds) } });
    await agg.refreshNow("1");
    const da = agg.snapshot().trucks.find((x) => x.name === "DA TRANSPORT");
    assert.equal(da.status, "failed");
    assert.equal(jobsStub.st.logins.includes("DA TRANSPORT"), false);
  } finally { await jobsStub.close(); }
});

test("the snapshot survives a restart through the store", async () => {
  const jobsStub = await startJobs();
  try {
    const store = new MemoryStore();
    const first = build(jobsStub, { store });
    await first.agg.refreshNow("1");
    const second = build(jobsStub, { store });
    assert.equal(second.agg.snapshot().generatedAt, null);
    assert.equal(await second.agg.restore(), 19);
    const snap = second.agg.snapshot();
    assert.ok(snap.generatedAt);
    assert.equal(snap.trucks.find((x) => x.name === "Gat - Sam").orders.ship.length, 2);
  } finally { await jobsStub.close(); }
});

test("start() runs the first refresh at boot and keeps refreshing on the interval; stop() ends it", async () => {
  const jobsStub = await startJobs();
  try {
    const { agg } = build(jobsStub);
    await agg.start({ firstDelayMs: 5 });
    await new Promise((r) => setTimeout(r, 60));
    await agg.idle();
    assert.equal(agg.snapshot().trucks.filter((x) => x.ok).length, 19);
    await agg.stop();
    const calls = jobsStub.st.calls.length;
    await new Promise((r) => setTimeout(r, 40));
    assert.equal(jobsStub.st.calls.length, calls);
  } finally { await jobsStub.close(); }
});

async function withApp(fn, jobsOpts) {
  const jobsStub = await startJobs(jobsOpts);
  const logs = [];
  const b = build(jobsStub, { logs });
  const server = createApp(b.config, { jobs: b.jobs, adminAggregate: b.agg, log: b.log });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const base = "http://127.0.0.1:" + server.address().port;
  let n = 0;
  const call = async (method, path, headers = {}, origin = ORIGIN) => {
    const h = { "X-Forwarded-For": "10.1.0." + ++n, ...headers };
    if (origin) h.Origin = origin;
    const res = await fetch(base + path, { method, headers: h });
    const text = await res.text();
    let json; try { json = JSON.parse(text); } catch { /* not json */ }
    return { status: res.status, json, text, headers: res.headers };
  };
  try { await fn({ call, agg: b.agg, logs, jobsStub }); } finally { await b.agg.stop(); await new Promise((r) => { server.closeAllConnections?.(); server.close(r); }); await jobsStub.close(); }
}
const bearer = (t) => ({ Authorization: "Bearer " + t });

test("GET /admin/orders-aggregate: superuser and logistique get it; carriers 403; no token 401", async () => {
  await withApp(async ({ call, agg, logs }) => {
    await agg.refreshNow("t");
    assert.equal((await call("GET", "/admin/orders-aggregate")).status, 401);
    assert.equal((await call("GET", "/admin/orders-aggregate", bearer("garbage"))).status, 401);
    assert.equal((await call("GET", "/admin/orders-aggregate", bearer(tok("carrier", "Gat - Sam")))).status, 403);
    const su = await call("GET", "/admin/orders-aggregate", bearer(tok("superuser", "SuperUser")));
    assert.equal(su.status, 200);
    assert.equal(su.json.trucks.length, 19);
    assert.ok(su.json.generatedAt);
    assert.equal(su.headers.get("access-control-allow-origin"), ORIGIN);
    assert.equal((await call("GET", "/admin/orders-aggregate", { "X-Quai-Session": tok("logistique") })).status, 200);
    // names only: no passwords, no job-service tokens anywhere in the answer or the logs
    assert.ok(!su.text.includes("-SECRET"));
    assert.ok(!su.text.includes("tok:"));
    assert.ok(!JSON.stringify(logs).includes("-SECRET"));
    assert.ok(!JSON.stringify(logs).includes("tok:"));
  });
});

test("CORS: preflight allows GET/POST and the session headers; unknown origins are refused", async () => {
  await withApp(async ({ call }) => {
    const pre = await call("OPTIONS", "/admin/orders-aggregate");
    assert.equal(pre.status, 204);
    assert.match(pre.headers.get("access-control-allow-methods"), /GET/);
    assert.match(pre.headers.get("access-control-allow-methods"), /POST/);
    assert.match(pre.headers.get("access-control-allow-headers"), /Authorization/);
    assert.equal((await call("OPTIONS", "/admin/orders-aggregate/refresh")).status, 204);
    assert.equal((await call("GET", "/admin/orders-aggregate", bearer(tok("superuser", "SuperUser")), "https://evil.example")).status, 403);
  });
});

test("POST /admin/orders-aggregate/refresh: starts one refresh, is rate limited, refused for carriers", async () => {
  await withApp(async ({ call, agg }) => {
    assert.equal((await call("POST", "/admin/orders-aggregate/refresh", bearer(tok("carrier", "Gat - Sam")))).status, 403);
    assert.equal((await call("POST", "/admin/orders-aggregate/refresh")).status, 401);
    assert.equal((await call("GET", "/admin/orders-aggregate/refresh", bearer(tok("superuser", "SuperUser")))).status, 405);
    const r1 = await call("POST", "/admin/orders-aggregate/refresh", bearer(tok("superuser", "SuperUser")));
    assert.equal(r1.status, 202);
    assert.equal(r1.json.started, true);
    const r2 = await call("POST", "/admin/orders-aggregate/refresh", bearer(tok("superuser", "SuperUser")));
    assert.equal(r2.status, 202);
    assert.equal(r2.json.started, false, "joins the running refresh");
    await agg.idle();
    const r3 = await call("POST", "/admin/orders-aggregate/refresh", bearer(tok("superuser", "SuperUser")));
    assert.equal(r3.status, 429);
    assert.ok(Number(r3.headers.get("retry-after")) > 0);
    assert.equal((await call("POST", "/admin/orders-aggregate", bearer(tok("superuser", "SuperUser")))).status, 405);
  });
});

test("before the first refresh the endpoint answers with pending trucks, not an error", async () => {
  await withApp(async ({ call }) => {
    const r = await call("GET", "/admin/orders-aggregate", bearer(tok("superuser", "SuperUser")));
    assert.equal(r.status, 200);
    assert.equal(r.json.generatedAt, null);
    assert.ok(r.json.trucks.every((x) => x.status === "pending" && x.ok === false));
  });
});

test("config: refresh interval is validated (30..3600) and defaults to 300", async () => {
  assert.equal(makeConfig({}).adminAggregate.intervalSeconds, 300);
  assert.equal(makeConfig({ ADMIN_AGGREGATE_REFRESH_SECONDS: "120" }).adminAggregate.intervalSeconds, 120);
  assert.throws(() => makeConfig({ ADMIN_AGGREGATE_REFRESH_SECONDS: "5" }), /ADMIN_AGGREGATE_REFRESH_SECONDS/);
});
