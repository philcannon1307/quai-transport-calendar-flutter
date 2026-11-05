import test from "node:test";
import assert from "node:assert/strict";
import { createApp } from "../src/app.js";
import { signSession } from "../src/jwt.js";
import { MemoryStore } from "../src/data/store-memory.js";
import { orderChangeSettings, ownsOrder, resolveDivision, resolveRecipients, serverOld, validateChange } from "../src/data/orderChanges.js";
import { SECRET, makeConfig } from "./helpers.js";

const mk = (over = {}) => makeConfig({ DATA_STORE: "memory", PUBLIC_BASE_URL: "https://quai.example.com", PUBLIC_SITE_URL: "https://app.example.com", ...over });
const ROWS = [
  { so_num: "SO20448", shipping_location_name: "Ste-Agathe", carrier_name: "Gat - Sam", customer: "Deroy", ship_date: "2026-11-04", city: "Saint-Donat" },
  { so_num: "TO555", shipping_location_name: "Lindsay", sale_location_name: "Gatineau", carrier_name: "Gat - Sam" },
  { so_num: "TO9", shipping_location_name: "Lindsay", sale_location_name: "Gatineau", carrier_name: "Gat - Sam" },
  { so_num: "SO1", shipping_location_name: "Ste-Agathe", carrier_name: "Gat - Sam" },
  { so_num: "SO5", shipping_location_name: "Ste-Agathe", carrier_name: "Gat - Sam" },
  { so_num: "SO6", shipping_location_name: "Ste-Agathe", carrier_name: "Gat - Sam" },
  { so_num: "SO8", shipping_location_name: "Rouyn-Noranda", carrier_name: "Gat - Sam" },
  { so_num: "SO7", shipping_location_name: "Lindsay", carrier_name: "Lindsay - Cole" },
  { so_num: "TO100", shipping_location_name: "Lindsay", sale_location_name: "Gatineau", carrier_name: "Lindsay - Brendan", ship_date: "2026-11-04" },
];
async function seeded() { const s = new MemoryStore(); await s.upsertHistory(ROWS.map((r) => ({ ...r }))); return s; }
async function boot({ over = {}, store = null, sent = [], failSend = false } = {}) {
  store = store ?? (await seeded());
  const mailer = { name: "fake", send: async (m) => { if (failSend) throw new Error("down"); sent.push(m); } };
  const server = createApp(mk(over), { store, mailer, log: () => {} });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { url: "http://127.0.0.1:" + server.address().port, store, sent, close: () => new Promise((r) => server.close(r)) };
}
const tok = (carrier, appRole) => signSession({ carrier, appRole, trucks: [], names: [carrier] }, SECRET, 600).token;
const GAT = () => tok("Gat - Sam", "carrier");
const LIND = () => tok("Lindsay - Brendan", "carrier");
const DA = () => tok("DA TRANSPORT", "carrier");
const LOGI = () => tok("SADM - Logistique", "logistique");
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
        assert.ok(j.recipients.length >= 1 && j.recipients.every((r) => r.email === undefined), "carrier response carries no mailboxes");
    assert.deepEqual(j.deliveredTo, []);
    assert.equal(app.sent.length, 1);
    assert.equal(app.sent[0].to, "communication@groupeql.com");
    assert.match(app.sent[0].subject, /^\[TEST\] Commande modifiée \/ Order changed — SO20448/);
    assert.match(app.sent[0].html, /2026-11-06/);
    assert.match(app.sent[0].html, /Gat - Sam/);
    assert.match(app.sent[0].html, /2026-11-04/);
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
    const res = await call(app, "POST", "/orders/TO555/changes", GAT(), { changes: [{ field: "truck", old: "A", new: "B" }], context: { shippingLocationName: "Mars", carrierName: "InterQL" } });
    const j = await res.json();
    assert.equal(j.emailStatus, "sent");
    assert.deepEqual(app.sent.map((m) => m.to).sort(), ["gatineau@groupeql.com", "lindsay@groupeql.com", "sadm@groupeql.com"]);
    assert.equal(app.sent.length, 3, "one change is never half-sent");
    assert.ok(app.sent.every((m) => !/^\[TEST\]/.test(m.subject)));
  } finally { await app.close(); }
});

test("server-side order data (delivery history) beats what the client says", async () => {
  const app = await boot({ over: { TEST_RECIPIENT_OVERRIDE: "off" } });
  try {
    await call(app, "POST", "/orders/SO7/changes", tok("Lindsay - Cole", "carrier"), { changes: [{ field: "memo", old: "", new: "hi" }], context: { shippingLocationName: "Gatineau", carrierName: "Gat - Sam" } });
    assert.deepEqual(app.sent.map((m) => m.to).sort(), ["lindsay@groupeql.com", "sadm@groupeql.com"], "client context (Gatineau, Gat - Sam) is ignored");
  } finally { await app.close(); }
});

test("preview: resolves recipients without storing or sending", async () => {
  const app = await boot();
  try {
    const res = await call(app, "POST", "/orders/TO9/changes/preview", GAT(), { context: { shippingLocationName: "Lindsay", saleLocationName: "Gatineau", carrierName: "InterQL" } });
    const j = await res.json();
    assert.equal(j.orderKind, "TO");
    assert.equal(j.testMode, true);
    assert.ok(j.recipients.length >= 2 && j.recipients.every((r) => r.email === undefined && Array.isArray(r.roles)), "carriers see roles, never internal mailboxes");
    assert.deepEqual(j.deliveredTo, []);
    const staff = await (await call(app, "POST", "/orders/TO9/changes/preview", LOGI(), {})).json();
    assert.deepEqual(staff.recipients.map((r) => r.email).sort(), ["gatineau@groupeql.com", "lindsay@groupeql.com", "sadm@groupeql.com"]);
    assert.ok(staff.recipients.some((r) => r.roles.includes("creator")) && staff.recipients.some((r) => r.roles.includes("receiver")));
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
    assert.equal(b.testMode, a.testMode, "duplicate answer carries the same testMode as a fresh send");
    assert.equal(b.testMode, true);
    assert.deepEqual(b.deliveredTo, a.deliveredTo);
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
    await call(app, "POST", "/orders/SO8/changes", GAT(), { changes: [{ field: "memo", old: "", new: "z" }], });
    assert.ok(app.sent.some((m) => m.to === "abitibi@groupeql.com"));
  } finally { await app.close(); }
});

test("an unsubscribed recipient is skipped, not mailed", async () => {
  const store = await seeded();
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

test("ownership: carrier A cannot read, preview or change carrier B's order; B and Logistique and SuperUser can", async () => {
  const app = await boot();
  try {
    const body = { changes: [{ field: "memo", old: "", new: "x" }] };
    for (const [m, p, b] of [["POST", "/orders/TO100/changes", body], ["POST", "/orders/TO100/changes/preview", {}], ["GET", "/orders/TO100/changes", undefined]]) {
      const r = await call(app, m, p, GAT(), b);
      assert.equal(r.status, 403, m + " " + p);
      assert.equal((await r.json()).error, "not_your_order");
      assert.equal((await call(app, m, p, DA(), b)).status, 403);
    }
    assert.equal(app.store.orderChanges.length, 0);
    assert.equal(app.sent.length, 0, "nothing mailed for a refused change");
    assert.equal((await call(app, "POST", "/orders/TO100/changes", LIND(), body)).status, 200);
    assert.equal((await call(app, "GET", "/orders/TO100/changes", LIND())).status, 200);
    assert.equal((await call(app, "POST", "/orders/TO100/changes", LOGI(), { changes: [{ field: "memo", old: "", new: "y" }] })).status, 200);
    assert.equal((await call(app, "GET", "/orders/TO100/changes", SUPER())).status, 200);
    assert.equal((await call(app, "GET", "/orders/TO100/changes", GAT())).status, 403, "history stays private to the owner");
  } finally { await app.close(); }
});

test("ownership: unknown order => carrier 403; Logistique allowed but only dispatcher + fallback, flagged unresolved", async () => {
  const app = await boot({ over: { TEST_RECIPIENT_OVERRIDE: "off" } });
  try {
    const body = { changes: [{ field: "memo", old: "", new: "x" }], context: { shippingLocationName: "Lindsay", carrierName: "Gat - Sam" } };
    assert.equal((await call(app, "POST", "/orders/SO999/changes", GAT(), body)).status, 403);
    const pv = await (await call(app, "POST", "/orders/SO999/changes/preview", LOGI(), body)).json();
    assert.deepEqual(pv.recipients.map((r) => r.email).sort(), ["comptabilite@groupeql.com", "sadm@groupeql.com"], "client-supplied location is ignored");
    assert.ok(pv.unresolved.length >= 1);
    const r = await call(app, "POST", "/orders/SO999/changes", LOGI(), body);
    assert.equal(r.status, 200);
    assert.deepEqual(app.sent.map((m) => m.to).sort(), ["comptabilite@groupeql.com", "sadm@groupeql.com"]);
  } finally { await app.close(); }
});

test("ownership: the changed-marker list only reports the caller's own orders (staff see all)", async () => {
  const app = await boot();
  try {
    await call(app, "POST", "/orders/TO100/changes", LIND(), { changes: [{ field: "memo", old: "", new: "a" }] });
    await call(app, "POST", "/orders/SO1/changes", GAT(), { changes: [{ field: "memo", old: "", new: "b" }] });
    const q = "/orders/changed?nums=TO100,SO1";
    assert.deepEqual(Object.keys((await (await call(app, "GET", q, GAT())).json()).changed), ["SO1"]);
    assert.deepEqual(Object.keys((await (await call(app, "GET", q, DA())).json()).changed), []);
    assert.deepEqual(Object.keys((await (await call(app, "GET", q, LOGI())).json()).changed).sort(), ["SO1", "TO100"]);
  } finally { await app.close(); }
});

test("ownsOrder: names are accent/case-insensitive; truck_name counts; no row => no carrier", () => {
  const s = { carrier: "SADM - Éric", appRole: "carrier", names: ["SADM - Éric", "sadm - eric"] };
  assert.equal(ownsOrder(s, { carrier_name: "sadm - eric" }), true);
  assert.equal(ownsOrder(s, { carrier_name: "SADM - David" }), false, "another SADM truck is not yours");
  assert.equal(ownsOrder({ carrier: "Gat - Sam", appRole: "carrier", names: ["Gat - Sam"] }, { carrier_name: "InterQL", truck_name: "Gat - Sam" }), true);
  assert.equal(ownsOrder(s, null), false);
  assert.equal(ownsOrder({ carrier: "x", appRole: "logistique", names: [] }, null), true);
  assert.equal(ownsOrder({ carrier: "x", appRole: "superuser", names: [] }, null), true);
});

test("old values come from the server when it knows them, not from the client", async () => {
  assert.equal(serverOld({ ship_date: new Date(2026, 10, 4) }, "ship_date"), "2026-11-04");
  assert.equal(serverOld({ city: "A" }, "memo"), undefined);
  const app = await boot();
  try {
    const j = await call(app, "POST", "/orders/SO20448/changes", GAT(), { changes: [{ field: "ship_date", old: "1999-01-01", new: "2026-11-06" }, { field: "city", old: "x", new: "Saint-Donat" }, { field: "memo", old: "client-old", new: "m" }] });
    assert.equal(j.status, 200);
    const rows = app.store.orderChanges;
    assert.deepEqual(rows.map((r) => [r.field, r.old_value, r.new_value]), [["ship_date", "2026-11-04", "2026-11-06"], ["memo", "client-old", "m"]], "city is a no-op against the real value");
  } finally { await app.close(); }
});

test("hourly mail cap does not split a change: a change mailing 5 inboxes is sent whole even after several notices", async () => {
  const app = await boot({ over: { TEST_RECIPIENT_OVERRIDE: "off" } });
  try {
    for (let i = 0; i < 6; i++) {
      const j = await (await call(app, "POST", "/orders/TO9/changes", GAT(), { changes: [{ field: "memo", old: "", new: "v" + i }] })).json();
      assert.equal(j.emailStatus, "sent", "change " + i);
    }
    assert.equal(app.sent.length, 18);
  } finally { await app.close(); }
});

test("dedupe + insert are one atomic step: parallel identical posts store one change", async () => {
  const app = await boot();
  try {
    const rs = await Promise.all(Array.from({ length: 5 }, () => call(app, "POST", "/orders/SO1/changes", GAT(), { changes: [{ field: "memo", old: "", new: "same" }] }).then((r) => r.json())));
    assert.equal(new Set(rs.map((r) => r.changeId)).size, 1);
    assert.equal(app.store.orderChanges.length, 1);
    assert.equal(app.sent.length, 1);
  } finally { await app.close(); }
});

test("location matching is by whole words; short keywords are refused", async () => {
  assert.equal(resolveDivision("Gat", []), null);
  assert.equal(resolveDivision("Entrepôt Gatineau", []).division, "gatineau");
  assert.equal(resolveDivision("Québec - Entrepôt", []).division, "quebec");
  assert.equal(resolveDivision("Gatineauville", []), null);
  assert.equal(resolveDivision("Sainte-Agathe-des-Monts", []).division, "sadm");
  const contacts = [{ division: "Abitibi", emails: ["a@groupeql.com"], location_keywords: ["rouyn noranda"] }];
  assert.equal(resolveDivision("Rouyn-Noranda", contacts).division, "Abitibi");
  assert.equal(resolveDivision("Noranda", contacts), null);
  const app = await boot();
  try {
    await call(app, "PUT", "/orders/division-contacts", SUPER(), { division: "Abitibi", emails: ["a@groupeql.com"], locationKeywords: ["ab", "rouyn"] });
    assert.deepEqual((await (await call(app, "GET", "/orders/division-contacts", SUPER())).json()).contacts[0].location_keywords, ["rouyn"]);
  } finally { await app.close(); }
});

// ---------------------------------------------------------------- line-by-line changes
const L = (lines, extra = {}) => ({ lines, ...extra });
const bad = (body, code) => assert.throws(() => validateChange(body), (e) => e.status === code || e.statusCode === code, JSON.stringify(body).slice(0, 80));

test("lines: validation - integers >= 0, blank before = 0, no-op lines skipped, max 50, duplicates, note-only", () => {
  const v = validateChange(L([{ item: "2x4x8", before: "10", after: "8", note: " cassé " }, { item: "Vis", after: 3 }, { item: "Same", before: "5", after: "5" }], { reason: "client" }));
  assert.deepEqual(v.changes, [
    { field: "item:2x4x8", old: "10", new: "8", note: "cassé" },
    { field: "item:Vis", old: "0", new: "3", note: "" },
  ]);
  assert.equal(v.reason, "client");
  assert.equal(validateChange(L([{ item: "A", before: "1", after: "0" }])).changes[0].new, "0", "after 0 = removed");
  // note only
  const n = validateChange(L([], { reason: "juste un mémo" }));
  assert.deepEqual(n.changes, [{ field: "note", old: "", new: "juste un mémo", note: "" }]);
  bad(L([]), 422); // nothing at all
  bad(L([{ item: "A", before: "1", after: "1" }]), 422); // only no-ops, no note
  bad(L([{ item: "A", before: "x", after: "1" }]), 422);
  bad(L([{ item: "A", before: "1", after: "-1" }]), 422);
  bad(L([{ item: "A", before: "1", after: "1.5" }]), 422);
  bad(L([{ item: "A", before: "1" }]), 422); // after missing
  bad(L([{ item: "A", before: 1, after: 2.5 }]), 422);
  bad(L([{ item: "A", before: "1234567", after: "1" }]), 422);
  bad(L([{ item: "", after: "1" }]), 422);
  bad(L([{ item: "x".repeat(71), after: "1" }]), 422);
  bad(L([{ item: "A", after: "1" }, { item: " a ", after: "2" }]), 422); // duplicate
  bad(L(Array.from({ length: 51 }, (_, i) => ({ item: "I" + i, after: "1" }))), 422);
  assert.equal(validateChange(L(Array.from({ length: 50 }, (_, i) => ({ item: "I" + i, after: "1" })))).changes.length, 50);
  bad({ lines: "nope" }, 400);
  bad(L(["x"]), 400);
  bad(L([{ item: 5, after: "1" }]), 400);
  bad(L([{ item: "A", after: "1", note: 7 }]), 400);
});

test("lines: stored per line with its note, history shows them, the e-mail lists each line in a table plus the general note", async () => {
  const app = await boot();
  try {
    const res = await call(app, "POST", "/orders/SO20448/changes", GAT(), L([
      { item: "2x4x8", before: "10", after: "8", note: "cassé" },
      { item: "Vis 3po", before: "", after: "20" },
      { item: "Clous", before: "4", after: "0" },
    ], { reason: "Appel du client" }));
    assert.equal(res.status, 200);
    assert.equal(app.sent.length, 1);
    const html = app.sent[0].html, text = app.sent[0].text;
    assert.match(html, /<table/);
    assert.match(html, /2x4x8/); assert.match(html, /cassé/);
    assert.match(html, /Ajouté \/ Added/); assert.match(html, /Retiré \/ Removed/); assert.match(html, /Quantité modifiée \/ Quantity changed/);
    assert.match(html, /Mémo \/ Note :<\/strong> Appel du client/);
    assert.match(text, /- 2x4x8 : 10 → 8 \(Quantité modifiée \/ Quantity changed\) — cassé/);
    assert.match(text, /- Vis 3po : 0 → 20 \(Ajouté/);
    assert.match(text, /Mémo \/ Note : Appel du client/);
    assert.match(app.sent[0].subject, /^\[TEST\] Commande modifiée \/ Order changed — SO20448/);
    const h = await (await call(app, "GET", "/orders/SO20448/changes", GAT())).json();
    assert.equal(h.changes.length, 1);
    const f = h.changes[0].fields;
    assert.equal(f.length, 3);
    const a = f.find((x) => x.field === "item:2x4x8");
    assert.deepEqual(a, { field: "item:2x4x8", old: "10", new: "8", note: "cassé" });
    assert.equal(f.find((x) => x.field === "item:Vis 3po").note, undefined, "no note key when empty");
    assert.equal(h.changes[0].reason, "Appel du client");
  } finally { await app.close(); }
});

test("lines: note-only change is stored and mailed; legacy field entries still render in the e-mail and history", async () => {
  const app = await boot();
  try {
    assert.equal((await call(app, "POST", "/orders/SO20448/changes", GAT(), L([], { reason: "Livrer après 14h" }))).status, 200);
    assert.match(app.sent[0].html, /Livrer après 14h/);
    assert.equal((await call(app, "POST", "/orders/SO20448/changes", GAT(), ch())).status, 200);
    assert.match(app.sent[1].html, /Date d.{1,6}expédition \/ Ship date/);
    assert.doesNotMatch(app.sent[1].html, /<table/);
    const h = await (await call(app, "GET", "/orders/SO20448/changes", GAT())).json();
    assert.equal(h.changes.length, 2);
  } finally { await app.close(); }
});

test("lines: dedupe sees the line note, ownership and bad input are enforced over HTTP", async () => {
  const app = await boot();
  try {
    const body = L([{ item: "A", before: "1", after: "2", note: "x" }]);
    assert.equal((await call(app, "POST", "/orders/SO20448/changes", GAT(), body)).status, 200);
    const dup = await (await call(app, "POST", "/orders/SO20448/changes", GAT(), body)).json();
    assert.equal(dup.duplicate, true);
    assert.equal((await call(app, "POST", "/orders/SO20448/changes", GAT(), L([{ item: "A", before: "1", after: "2", note: "y" }]))).status, 200, "different note = different change");
    assert.equal(app.sent.length, 2);
    assert.equal((await call(app, "POST", "/orders/SO20448/changes", LIND(), body)).status, 403);
    assert.equal((await call(app, "POST", "/orders/SO20448/changes", GAT(), L([{ item: "A", after: "-3" }]))).status, 422);
    assert.equal((await call(app, "POST", "/orders/SO20448/changes", GAT(), L([]))).status, 422);
    assert.equal((await call(app, "POST", "/orders/SO20448/changes", LOGI(), body)).status, 200);
  } finally { await app.close(); }
});
