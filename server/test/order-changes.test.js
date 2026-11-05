import test from "node:test";
import assert from "node:assert/strict";
import { createApp } from "../src/app.js";
import { signSession } from "../src/jwt.js";
import { MemoryStore } from "../src/data/store-memory.js";
import { orderChangeSettings, resolveRecipients, validateChange } from "../src/data/orderChanges.js";
import { SECRET, makeConfig } from "./helpers.js";

const mk = (over = {}) => makeConfig({ DATA_STORE: "memory", PUBLIC_BASE_URL: "https://quai.example.com", PUBLIC_SITE_URL: "https://app.example.com", ...over });
async function boot({ over = {}, store = new MemoryStore(), sent = [], failSend = false } = {}) {
  const mailer = { name: "fake", send: async (m) => { if (failSend) throw new Error("down"); sent.push(m); } };
  const server = createApp(mk(over), { store, mailer, log: () => {} });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { url: "http://127.0.0.1:" + server.address().port, store, sent, close: () => new Promise((r) => server.close(r)) };
}
const tok = (carrier, appRole) => signSession({ carrier, appRole, trucks: [], names: [carrier] }, SECRET, 600).token;
const GAT = () => tok("Gat - Sam", "carrier");
const SUPER = () => tok("SuperUser", "superuser");
const call = (app, method, path, token, body) =>
  fetch(app.url + path, { method, headers: { "Content-Type": "application/json", "X-Quai-Session": token ?? "" }, body: body === undefined ? undefined : JSON.stringify(body) });
const ctxSO = { shippingLocationName: "Ste-Agathe", carrierName: "SADM - Jayson", customer: "Deroy" };
const ch = (extra = {}) => ({ changes: [{ field: "ship_date", old: "2026-11-04", new: "2026-11-06" }], reason: "client request", context: ctxSO, ...extra });

test("settings: test override defaults ON, can be turned off, must be @groupeql.com", () => {
  assert.equal(orderChangeSettings({}).settings.testOverride, "communication@groupeql.com");
  assert.equal(orderChangeSettings({ TEST_RECIPIENT_OVERRIDE: "off" }).settings.testOverride, null);
  assert.equal(orderChangeSettings({ TEST_RECIPIENT_OVERRIDE: "me@groupeql.com" }).settings.testOverride, "me@groupeql.com");
  assert.ok(orderChangeSettings({ TEST_RECIPIENT_OVERRIDE: "x@evil.com" }).errors.length > 0);
  assert.ok(orderChangeSettings({ DISPATCHER_EMAIL: "x@evil.com" }).errors.length > 0);
});

test("recipients: TO = creating + receiving division, SO = leaving division; plus carrier and dispatcher; deduped", () => {
  const to = resolveRecipients({ kind: "TO", shippingLocation: "Lindsay", receivingLocation: "Gatineau", carrierName: "InterQL", contacts: [], dispatcher: "sadm@groupeql.com" });
  const by = Object.fromEntries(to.recipients.map((r) => [r.email, r.roles]));
  assert.deepEqual(by["lindsay@groupeql.com"], ["creator"]);
  assert.deepEqual(by["gatineau@groupeql.com"], ["receiver"]);
  assert.deepEqual(by["sadm@groupeql.com"], ["carrier", "dispatcher"], "Gooseneck group inbox = dispatcher inbox: one mail, two roles");
  const so = resolveRecipients({ kind: "SO", shippingLocation: "Québec - Entrepôt", receivingLocation: "Gatineau", carrierName: "Gat - Sam", contacts: [], dispatcher: "sadm@groupeql.com" });
  const emails = so.recipients.map((r) => r.email).sort();
  assert.deepEqual(emails, ["gatineau@groupeql.com", "quebec@groupeql.com", "sadm@groupeql.com"], "the receiving place is ignored for a sales order");
  const unk = resolveRecipients({ kind: "SO", shippingLocation: "Mars", carrierName: "", contacts: [], dispatcher: "sadm@groupeql.com" });
  assert.ok(unk.unresolved.length === 1 && unk.recipients.some((r) => r.roles.includes("fallback")));
});

test("recipients: SuperUser division contacts win over the built-in map", () => {
  const r = resolveRecipients({ kind: "SO", shippingLocation: "Entrepôt Rouyn", carrierName: "", contacts: [{ division: "Abitibi", emails: ["abitibi@groupeql.com"], location_keywords: ["rouyn"] }], dispatcher: "sadm@groupeql.com" });
  assert.ok(r.recipients.some((x) => x.email === "abitibi@groupeql.com" && x.roles.includes("origin")));
});

test("validation: unknown field, no-op, duplicate, oversize, bad types", () => {
  assert.throws(() => validateChange({ changes: [{ field: "password", old: "a", new: "b" }] }), /field_not_allowed/);
  assert.throws(() => validateChange({ changes: [{ field: "memo", old: "a", new: "a" }] }), /no_changes/);
  assert.throws(() => validateChange({ changes: [{ field: "memo", old: "a", new: "b" }, { field: "memo", old: "a", new: "c" }] }), /duplicate_field/);
  assert.throws(() => validateChange({}), /changes_required/);
  assert.throws(() => validateChange({ changes: [{ field: "memo", old: {}, new: "b" }] }), /change_invalid/);
  const ok = validateChange({ changes: [{ field: "item:2x4 SPF", old: "10", new: "12" }, { field: "memo", old: null, new: "x".repeat(900) }] });
  assert.equal(ok.changes[1].new.length, 500);
});

test("POST stores the diff, sends ONE notice to the override only, history + marker work", async () => {
  const app = await boot();
  try {
    const res = await call(app, "POST", "/orders/SO20448/changes", GAT(), ch());
    assert.equal(res.status, 200);
    const j = await res.json();
    assert.equal(j.emailStatus, "test_override");
    assert.equal(j.testMode, true);
    assert.deepEqual(j.deliveredTo, ["communication@groupeql.com"]);
    assert.ok(j.recipients.some((r) => r.email === "sadm@groupeql.com"), "intended recipients are still reported");
    assert.equal(app.sent.length, 1);
    assert.equal(app.sent[0].to, "communication@groupeql.com");
    assert.match(app.sent[0].subject, /^\[TEST\] Commande modifiée \/ Order changed — SO20448/);
    assert.match(app.sent[0].html, /2026-11-06/);
    assert.match(app.sent[0].html, /Gat - Sam/);
    assert.match(app.sent[0].html, /sadm@groupeql\.com/, "test mail lists who would have been notified");

    const h = await (await call(app, "GET", "/orders/so20448/changes", GAT())).json();
    assert.equal(h.changed, true);
    assert.equal(h.changes.length, 1);
    assert.deepEqual(h.changes[0].fields, [{ field: "ship_date", old: "2026-11-04", new: "2026-11-06" }]);
    assert.equal(h.changes[0].changedBy, "Gat - Sam");

    const m = await (await call(app, "GET", "/orders/changed?nums=SO20448,SO1,bad", GAT())).json();
    assert.equal(m.changed.SO20448.count, 1);
    assert.equal(m.changed.SO1, undefined);
    const rows = app.store.orderChanges;
    assert.equal(rows[0].changed_by, "Gat - Sam", "author comes from the session");
    assert.equal(rows[0].email_status, "test_override");
  } finally { await app.close(); }
});

test("with the override OFF the real recipients are mailed (TO: both divisions)", async () => {
  const app = await boot({ over: { TEST_RECIPIENT_OVERRIDE: "off" } });
  try {
    const res = await call(app, "POST", "/orders/TO555/changes", GAT(), { changes: [{ field: "truck", old: "A", new: "B" }], context: { shippingLocationName: "Lindsay", saleLocationName: "Gatineau", carrierName: "InterQL" } });
    const j = await res.json();
    assert.equal(j.emailStatus, "sent");
    assert.deepEqual(app.sent.map((m) => m.to).sort(), ["gatineau@groupeql.com", "lindsay@groupeql.com", "sadm@groupeql.com"]);
    assert.ok(app.sent.every((m) => !/^\[TEST\]/.test(m.subject)));
  } finally { await app.close(); }
});

test("server-side order data (delivery history) beats what the client says", async () => {
  const store = new MemoryStore();
  await store.upsertHistory([{ so_num: "SO7", shipping_location_name: "Lindsay", carrier_name: "Lindsay - Cole" }]);
  const app = await boot({ over: { TEST_RECIPIENT_OVERRIDE: "off" }, store });
  try {
    await call(app, "POST", "/orders/SO7/changes", GAT(), { changes: [{ field: "memo", old: "", new: "hi" }], context: { shippingLocationName: "Gatineau", carrierName: "Gat - Sam" } });
    assert.deepEqual(app.sent.map((m) => m.to).sort(), ["lindsay@groupeql.com", "sadm@groupeql.com"]);
  } finally { await app.close(); }
});

test("preview: resolves recipients without storing or sending", async () => {
  const app = await boot();
  try {
    const res = await call(app, "POST", "/orders/TO9/changes/preview", GAT(), { context: { shippingLocationName: "Lindsay", saleLocationName: "Gatineau", carrierName: "InterQL" } });
    const j = await res.json();
    assert.equal(j.orderKind, "TO");
    assert.equal(j.testMode, true);
    assert.deepEqual(j.recipients.map((r) => r.email).sort(), ["gatineau@groupeql.com", "lindsay@groupeql.com", "sadm@groupeql.com"]);
    assert.equal(app.store.orderChanges.length, 0);
    assert.equal(app.sent.length, 0);
  } finally { await app.close(); }
});

test("dedupe: the same change twice mails once; a different change mails again", async () => {
  const app = await boot();
  try {
    const a = await (await call(app, "POST", "/orders/SO20448/changes", GAT(), ch())).json();
    const b = await (await call(app, "POST", "/orders/SO20448/changes", GAT(), ch())).json();
    assert.equal(b.duplicate, true);
    assert.equal(b.changeId, a.changeId);
    assert.equal(app.sent.length, 1);
    assert.equal(app.store.orderChanges.length, 1);
    await call(app, "POST", "/orders/SO20448/changes", GAT(), ch({ changes: [{ field: "memo", old: "", new: "x" }] }));
    assert.equal(app.sent.length, 2);
  } finally { await app.close(); }
});

test("rate limit: a login cannot post more than 20 changes in 10 minutes", async () => {
  const app = await boot();
  try {
    let last = 0;
    for (let i = 0; i < 22; i++) last = (await call(app, "POST", "/orders/SO1/changes", GAT(), { changes: [{ field: "memo", old: "", new: "v" + i }], context: ctxSO })).status;
    assert.equal(last, 429);
  } finally { await app.close(); }
});

test("auth + validation errors: no session 401, bad number 400, bad field 422, role gate 403", async () => {
  const app = await boot();
  try {
    assert.equal((await call(app, "POST", "/orders/SO1/changes", "", ch())).status, 401);
    assert.equal((await call(app, "GET", "/orders/SO1/changes", "")).status, 401);
    assert.equal((await call(app, "POST", "/orders/XX1/changes", GAT(), ch())).status, 400);
    assert.equal((await call(app, "POST", "/orders/SO1/changes", GAT(), { changes: [{ field: "x", old: "a", new: "b" }] })).status, 422);
    assert.equal((await call(app, "POST", "/orders/SO1/changes", GAT(), { changes: [] })).status, 422);
    assert.equal((await call(app, "DELETE", "/orders/SO1/changes", GAT())).status, 405);
    const only = await boot({ over: { ORDER_CHANGE_ROLES: "superuser" } });
    try { assert.equal((await call(only, "POST", "/orders/SO1/changes", GAT(), ch())).status, 403); assert.equal((await call(only, "POST", "/orders/SO1/changes", SUPER(), ch())).status, 200); } finally { await only.close(); }
  } finally { await app.close(); }
});

test("a failing mail provider keeps the change and records email_status=failed", async () => {
  const app = await boot({ failSend: true });
  try {
    const j = await (await call(app, "POST", "/orders/SO5/changes", GAT(), ch())).json();
    assert.equal(j.emailStatus, "failed");
    assert.equal(app.store.orderChanges.length, 1);
    assert.equal(app.store.orderChanges[0].email_status, "failed");
  } finally { await app.close(); }
});

test("division contacts: SuperUser only, groupeql.com only, and they change who is notified", async () => {
  const app = await boot({ over: { TEST_RECIPIENT_OVERRIDE: "off" } });
  try {
    assert.equal((await call(app, "GET", "/orders/division-contacts", GAT())).status, 403);
    assert.equal((await call(app, "PUT", "/orders/division-contacts", GAT(), { division: "Abitibi", emails: ["a@groupeql.com"] })).status, 403);
    assert.equal((await call(app, "PUT", "/orders/division-contacts", SUPER(), { division: "Abitibi", emails: ["a@evil.com"] })).status, 422);
    assert.equal((await call(app, "PUT", "/orders/division-contacts", SUPER(), { division: "Abitibi", emails: ["abitibi@groupeql.com"], locationKeywords: ["rouyn"] })).status, 200);
    const list = await (await call(app, "GET", "/orders/division-contacts", SUPER())).json();
    assert.equal(list.contacts[0].division, "Abitibi");
    await call(app, "POST", "/orders/SO8/changes", GAT(), { changes: [{ field: "memo", old: "", new: "z" }], context: { shippingLocationName: "Rouyn-Noranda" } });
    assert.ok(app.sent.some((m) => m.to === "abitibi@groupeql.com"));
  } finally { await app.close(); }
});

test("an unsubscribed recipient is skipped, not mailed", async () => {
  const store = new MemoryStore();
  store.suppressed.set("communication@groupeql.com", { reason: "unsubscribe" });
  const app = await boot({ store });
  try {
    const j = await (await call(app, "POST", "/orders/SO6/changes", GAT(), ch())).json();
    assert.equal(j.emailStatus, "suppressed");
    assert.equal(app.sent.length, 0);
  } finally { await app.close(); }
});

test("schema + migration declare order_changes and division_contacts", async () => {
  const { readFile } = await import("node:fs/promises");
  for (const f of ["../db/schema.sql", "../db/migrations/2026-11-05-order-changes.sql"]) {
    const sql = await readFile(new URL(f, import.meta.url), "utf8");
    assert.match(sql, /create table if not exists order_changes/);
    assert.match(sql, /create table if not exists division_contacts/);
  }
});
