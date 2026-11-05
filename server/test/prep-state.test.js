import test from "node:test";
import assert from "node:assert/strict";
import { createApp } from "../src/app.js";
import { signSession } from "../src/jwt.js";
import { MemoryStore } from "../src/data/store-memory.js";
import { canSetPrep, strictOrderNum, validDate } from "../src/data/prepState.js";
import { isLogistiqueUnit } from "../src/roster.js";
import { SECRET, makeConfig } from "./helpers.js";

const mk = (over = {}) => makeConfig({ DATA_STORE: "memory", PUBLIC_BASE_URL: "https://quai.example.com", PUBLIC_SITE_URL: "https://app.example.com", ...over });
const ROWS = [
  { so_num: "SO1", shipping_location_name: "Ste-Agathe", carrier_name: "Gat - Sam" },
  { so_num: "SO2", shipping_location_name: "Ste-Agathe", carrier_name: "Lindsay - Cole" },
  { so_num: "TO9", shipping_location_name: "Lindsay", sale_location_name: "Gatineau", carrier_name: "Gat - Sam" },
];
async function boot() {
  const store = new MemoryStore();
  await store.upsertHistory(ROWS.map((r) => ({ ...r })));
  const server = createApp(mk(), { store, mailer: { name: "fake", send: async () => {} }, log: () => {} });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { url: "http://127.0.0.1:" + server.address().port, store, close: () => new Promise((r) => server.close(r)) };
}
const tok = (carrier, appRole, uid) => signSession({ carrier, appRole, trucks: [], names: [carrier] }, SECRET, 600, uid).token;
const GAT = () => tok("Gat - Sam", "carrier");
const LINDSAY = () => tok("Lindsay - Cole", "carrier");
const LOGI = () => tok("SADM - Logistique", "logistique");
const QC = () => tok("Québec - Logistique", "logistique");
const SUPER = () => tok("SuperUser", "superuser");
const call = (app, method, path, token, body) =>
  fetch(app.url + path, { method, headers: { "Content-Type": "application/json", "X-Quai-Session": token ?? "" }, body: body === undefined ? undefined : JSON.stringify(body) });
const D = "2026-11-06";

test("pure helpers: roles, order numbers, dates", () => {
  assert.equal(canSetPrep({ appRole: "logistique" }), true);
  assert.equal(canSetPrep({ appRole: "superuser" }), true);
  assert.equal(canSetPrep({ appRole: "carrier" }), false);
  assert.equal(strictOrderNum("so12"), "SO12");
  assert.throws(() => strictOrderNum("SO1\r\n"), /order_num_invalid/);
  assert.throws(() => strictOrderNum("XX1"), /order_num_invalid/);
  assert.equal(validDate("2026-11-06"), true);
  assert.equal(validDate("2026-02-30"), false);
  assert.equal(validDate("2026-1-6"), false);
});

test("roster: every '<unit> - Logistique' login is a logistics unit, nobody else", () => {
  for (const n of ["SADM - Logistique", "Québec - Logistique", "Lindsay - Logistique", "Muskoka - Logistique", "quebec - logistique"]) assert.equal(isLogistiqueUnit(n), true, n);
  for (const n of ["SADM - David", "Logistique", " - Logistique", "InterQL", "SuperUser", "", null, "Logistique - Marc"]) assert.equal(isLogistiqueUnit(n), false, String(n));
});

test("auth: no/invalid session is 401 on every method", async () => {
  const app = await boot();
  try {
    assert.equal((await call(app, "GET", "/prep-state?from=" + D + "&to=" + D, null)).status, 401);
    assert.equal((await call(app, "PUT", "/prep-state/SO1", "garbage", { prepared: true })).status, 401);
    assert.equal((await call(app, "GET", "/prep-state/SO1/history", null)).status, 401);
  } finally { await app.close(); }
});

test("PUT: logistique and superuser can prepare; carriers get 403 and nothing is stored", async () => {
  const app = await boot();
  try {
    assert.equal((await call(app, "PUT", "/prep-state/SO1", GAT(), { prepared: true, date: D })).status, 403);
    assert.equal(app.store.prepStates.size, 0);
    const a = await call(app, "PUT", "/prep-state/SO1", LOGI(), { prepared: true, date: D, label: "Marc" });
    assert.equal(a.status, 200);
    const j = await a.json();
    assert.deepEqual([j.orderNum, j.date, j.prepared, j.by, j.label, j.changed], ["SO1", D, true, "SADM - Logistique", "Marc", true]);
    assert.ok(j.at);
    assert.equal((await call(app, "PUT", "/prep-state/TO9", SUPER(), { prepared: true, date: D })).status, 200);
  } finally { await app.close(); }
});

test("shared per order: another logistics unit sees and can undo it", async () => {
  const app = await boot();
  try {
    await call(app, "PUT", "/prep-state/SO1", LOGI(), { prepared: true, date: D });
    const seen = await (await call(app, "GET", "/prep-state?from=" + D + "&to=" + D, QC())).json();
    assert.deepEqual(seen.states.map((x) => [x.orderNum, x.by]), [["SO1", "SADM - Logistique"]]);
    const undo = await (await call(app, "PUT", "/prep-state/SO1", QC(), { prepared: false, date: D })).json();
    assert.equal(undo.prepared, false);
    assert.equal(undo.changed, true);
    const after = await (await call(app, "GET", "/prep-state?from=" + D + "&to=" + D, LOGI())).json();
    assert.deepEqual(after.states, []);
  } finally { await app.close(); }
});

test("idempotent: repeating the same state changes nothing and adds no history", async () => {
  const app = await boot();
  try {
    const first = await (await call(app, "PUT", "/prep-state/SO1", LOGI(), { prepared: true, date: D })).json();
    const again = await (await call(app, "PUT", "/prep-state/SO1", QC(), { prepared: true, date: D })).json();
    assert.equal(first.changed, true);
    assert.equal(again.changed, false);
    assert.equal(again.by, "SADM - Logistique", "the original actor is kept");
    const none = await (await call(app, "PUT", "/prep-state/SO2", LOGI(), { prepared: false, date: D })).json();
    assert.equal(none.changed, false);
    assert.equal(app.store.prepHistory.length, 1);
  } finally { await app.close(); }
});

test("key = order + date: the same order on two days is prepared separately", async () => {
  const app = await boot();
  try {
    await call(app, "PUT", "/prep-state/SO1", LOGI(), { prepared: true, date: "2026-11-06" });
    const wide = await (await call(app, "GET", "/prep-state?from=2026-11-05&to=2026-11-09", LOGI())).json();
    assert.equal(wide.states.length, 1);
    const other = await (await call(app, "GET", "/prep-state?from=2026-11-07&to=2026-11-09", LOGI())).json();
    assert.deepEqual(other.states, []);
    const byOrder = await (await call(app, "GET", "/prep-state?orders=SO1,so2,bad", LOGI())).json();
    assert.deepEqual(byOrder.states.map((x) => x.date), ["2026-11-06"]);
    await call(app, "PUT", "/prep-state/SO1", LOGI(), { prepared: true }); // no date = whole-order flag
    assert.equal((await (await call(app, "GET", "/prep-state?orders=SO1", LOGI())).json()).states.length, 2);
  } finally { await app.close(); }
});

test("carriers read only their own orders", async () => {
  const app = await boot();
  try {
    await call(app, "PUT", "/prep-state/SO1", LOGI(), { prepared: true, date: D });
    await call(app, "PUT", "/prep-state/SO2", LOGI(), { prepared: true, date: D });
    const q = "/prep-state?from=" + D + "&to=" + D;
    assert.deepEqual((await (await call(app, "GET", q, GAT())).json()).states.map((x) => x.orderNum), ["SO1"]);
    assert.deepEqual((await (await call(app, "GET", q, LINDSAY())).json()).states.map((x) => x.orderNum), ["SO2"]);
    assert.equal((await (await call(app, "GET", q, LOGI())).json()).states.length, 2);
  } finally { await app.close(); }
});

test("validation: bad order number, body, date, range, method", async () => {
  const app = await boot();
  try {
    assert.equal((await call(app, "PUT", "/prep-state/XX1", LOGI(), { prepared: true })).status, 400);
    assert.equal((await call(app, "PUT", "/prep-state/SO1%0d%0a", LOGI(), { prepared: true })).status, 400);
    assert.equal((await call(app, "PUT", "/prep-state/%E0%A4%A", LOGI(), { prepared: true })).status, 400);
    assert.equal((await call(app, "PUT", "/prep-state/SO1", LOGI(), {})).status, 400);
    assert.equal((await call(app, "PUT", "/prep-state/SO1", LOGI(), { prepared: "yes" })).status, 400);
    assert.equal((await call(app, "PUT", "/prep-state/SO1", LOGI(), { prepared: true, date: "2026-13-01" })).status, 400);
    assert.equal((await call(app, "GET", "/prep-state", LOGI())).status, 400);
    assert.equal((await call(app, "GET", "/prep-state?from=2026-11-09&to=2026-11-01", LOGI())).status, 400);
    assert.equal((await call(app, "GET", "/prep-state?from=2026-01-01&to=2026-12-31", LOGI())).status, 400);
    assert.equal((await call(app, "DELETE", "/prep-state/SO1", LOGI())).status, 405);
    assert.equal((await call(app, "POST", "/prep-state", LOGI(), {})).status, 405);
    assert.equal((await call(app, "GET", "/prep-state/SO1/other", LOGI())).status, 404);
    assert.equal(app.store.prepStates.size, 0);
  } finally { await app.close(); }
});

test("history: staff only, newest first, label capped, 90-day window", async () => {
  const app = await boot();
  try {
    await call(app, "PUT", "/prep-state/SO1", LOGI(), { prepared: true, date: D, label: "x".repeat(100) });
    await call(app, "PUT", "/prep-state/SO1", QC(), { prepared: false, date: D });
    assert.equal((await call(app, "GET", "/prep-state/SO1/history", GAT())).status, 403);
    const h = await (await call(app, "GET", "/prep-state/SO1/history?date=" + D, SUPER())).json();
    assert.deepEqual(h.history.map((x) => [x.prepared, x.by]), [[false, "Québec - Logistique"], [true, "SADM - Logistique"]]);
    assert.equal(h.history[1].label.length, 40);
    app.store.prepHistory[0].at = new Date(Date.now() - 100 * 86_400_000).toISOString();
    const h2 = await (await call(app, "GET", "/prep-state/SO1/history", SUPER())).json();
    assert.equal(h2.history.length, 1, "entries older than 90 days are not listed");
  } finally { await app.close(); }
});

test("rate limit: more than 120 changes a minute from one login gets 429", async () => {
  const app = await boot();
  try {
    let last = 0;
    for (let i = 0; i < 125; i++) last = (await call(app, "PUT", "/prep-state/SO1", LOGI(), { prepared: i % 2 === 0, date: D })).status;
    assert.equal(last, 429);
    assert.equal((await call(app, "PUT", "/prep-state/SO1", QC(), { prepared: true, date: D })).status, 200, "another login has its own budget");
  } finally { await app.close(); }
});

test("pruning drops history older than 90 days and states older than 180 days", async () => {
  const s = new MemoryStore();
  await s.setPrepState({ orderNum: "SO1", date: D, prepared: true, actor: "a", label: "", atIso: "2020-01-01T00:00:00.000Z" });
  await s.setPrepState({ orderNum: "SO2", date: D, prepared: true, actor: "a", label: "", atIso: new Date().toISOString() });
  await s.prunePrep(new Date(Date.now() - 90 * 86_400_000).toISOString(), new Date(Date.now() - 180 * 86_400_000).toISOString());
  assert.deepEqual([...s.prepStates.keys()], ["SO2|" + D]);
  assert.equal(s.prepHistory.length, 1);
});
