import test from "node:test";
import assert from "node:assert/strict";
import { createApp } from "../src/app.js";
import { signSession } from "../src/jwt.js";
import { MemoryStore } from "../src/data/store-memory.js";
import { SECRET, makeConfig } from "./helpers.js";

const BASE = "https://quai.example.com";

function mkConfig(over = {}) {
  return makeConfig({ DATA_STORE: "memory", PUBLIC_BASE_URL: BASE, PUBLIC_SITE_URL: "https://app.example.com", ...over });
}

async function boot({ config = mkConfig(), store = new MemoryStore(), sent = [], failSend = 0 } = {}) {
  let fails = failSend;
  const mailer = { name: "fake", send: async (m) => { if (fails > 0) { fails--; throw new Error("provider down"); } sent.push(m); } };
  const server = createApp(config, { store, mailer });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const url = "http://127.0.0.1:" + server.address().port;
  return { server, url, store, sent, close: () => new Promise((r) => server.close(r)) };
}

const tokenFor = (carrier, appRole, names = [carrier]) => signSession({ carrier, appRole, trucks: [], names }, SECRET, 600).token;
const SUPER = () => tokenFor("SuperUser", "superuser", []);
const GAT = () => tokenFor("Gat - Sam", "carrier");
const LOGI = () => tokenFor("SADM - Logistique", "logistique");

const op = (app, token, body) =>
  fetch(app.url + "/functions/v1/quai-data", { method: "POST", headers: { "Content-Type": "application/json", "X-Quai-Session": token ?? "" }, body: JSON.stringify(body) });

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]);
const up = (app, token, bucket, path, bytes = PNG, type = "image/png") =>
  fetch(app.url + "/functions/v1/quai-data?op=upload&bucket=" + bucket + "&path=" + encodeURIComponent(path), { method: "POST", headers: { "Content-Type": type, "X-Quai-Session": token }, body: bytes });

const uuid = () => crypto.randomUUID();

test("data API answers 503 when no database is configured", async () => {
  const server = createApp(makeConfig(), {});
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const res = await fetch("http://127.0.0.1:" + server.address().port + "/functions/v1/quai-data", { method: "POST", body: "{}" });
  assert.equal(res.status, 503);
  await new Promise((r) => server.close(r));
});

test("session is required: missing, forged and expired tokens are 401", async () => {
  const app = await boot();
  try {
    assert.equal((await op(app, "", { op: "history.list", from: "2026-01-01", to: "2026-02-01" })).status, 401);
    assert.equal((await op(app, "a.b.c", { op: "history.list" })).status, 401);
    const wrong = signSession({ carrier: "X", appRole: "carrier", trucks: [], names: [] }, "another-secret-another-secret-another-1234", 600).token;
    assert.equal((await op(app, wrong, { op: "history.list" })).status, 401);
    const expired = signSession({ carrier: "X", appRole: "carrier", trucks: [], names: [] }, SECRET, -10).token;
    assert.equal((await op(app, expired, { op: "history.list" })).status, 401);
    const bearer = await fetch(app.url + "/functions/v1/quai-data", { method: "POST", headers: { Authorization: "Bearer " + GAT(), "Content-Type": "application/json" }, body: JSON.stringify({ op: "history.list", from: "2026-01-01", to: "2026-02-01" }) });
    assert.equal(bearer.status, 200, "Authorization: Bearer is accepted too");
  } finally { await app.close(); }
});

test("announcements: SuperUser only, public read shows active ones with their pictures", async () => {
  const app = await boot();
  try {
    assert.equal((await op(app, GAT(), { op: "announcement.insert", row: { title: "t", body: "b" } })).status, 403);
    const ins = await op(app, SUPER(), { op: "announcement.insert", row: { title: "Fermé lundi", body: "Jour férié", title_fr: "Fermé", body_fr: "Férié" } });
    assert.equal(ins.status, 200);
    const { id } = await ins.json();
    assert.match(id, /^[0-9a-f-]{36}$/);

    // picture: upload (superuser) then link
    const path = id + "/1730000000000-photo.png";
    const u = await up(app, SUPER(), "announcement-images", path);
    assert.equal(u.status, 200);
    const { url } = await u.json();
    assert.equal(url, BASE + "/storage/v1/object/public/announcement-images/" + id + "/1730000000000-photo.png");
    assert.equal((await op(app, SUPER(), { op: "announcement.image.add", announcementId: id, url })).status, 200);
    assert.equal((await op(app, SUPER(), { op: "announcement.image.add", announcementId: id, url: "https://evil.example/x.png" })).status, 422);

    const list = await (await fetch(app.url + "/rest/v1/announcements?select=*&is_active=eq.true&order=created_at.desc")).json();
    assert.equal(list.length, 1);
    assert.equal(list[0].title, "Fermé lundi");
    const imgs = await (await fetch(app.url + "/rest/v1/announcement_images?select=announcement_id,storage_url&announcement_id=in.(" + id + ")")).json();
    assert.deepEqual(imgs.map((i) => i.storage_url), [url]);

    // the public file route serves the picture with safe headers
    const file = await fetch(url.replace(BASE, app.url));
    assert.equal(file.status, 200);
    assert.equal(file.headers.get("content-type"), "image/png");
    assert.equal(file.headers.get("x-content-type-options"), "nosniff");
    assert.deepEqual(Buffer.from(await file.arrayBuffer()), PNG);

    assert.equal((await op(app, SUPER(), { op: "announcement.update", id, row: { title: "Nouveau titre" } })).status, 200);
    assert.equal((await op(app, SUPER(), { op: "files.remove", bucket: "announcement-images", paths: [path] })).status, 200);
    assert.equal((await fetch(url.replace(BASE, app.url))).status, 404);
    assert.equal((await op(app, SUPER(), { op: "announcement.delete", id })).status, 200);
    assert.deepEqual(await (await fetch(app.url + "/rest/v1/announcements")).json(), []);
    assert.equal((await op(app, SUPER(), { op: "announcement.insert", row: { title: "", body: "x" } })).status, 400);
  } finally { await app.close(); }
});

test("uploads: type, magic bytes, paths, roles, size and duplicates are enforced", async () => {
  const app = await boot();
  try {
    const day = "2026-11-04";
    assert.equal((await up(app, GAT(), "receipts", day + "/r.png")).status, 200);
    assert.equal((await up(app, GAT(), "receipts", day + "/r.png")).status, 409, "no overwrite");
    assert.equal((await up(app, GAT(), "receipts", day + "/h.png", Buffer.from("<html>"), "image/png")).status, 415, "html disguised as png");
    assert.equal((await up(app, GAT(), "receipts", day + "/s.svg", Buffer.from("<svg/>"), "image/svg+xml")).status, 415);
    assert.equal((await up(app, GAT(), "receipts", "../x.png")).status, 422);
    assert.equal((await up(app, GAT(), "secrets", day + "/r.png")).status, 422);
    assert.equal((await up(app, GAT(), "receipts", "bol/" + day + "/b.png")).status, 403, "BOL needs logistique or superuser");
    assert.equal((await up(app, LOGI(), "receipts", "bol/" + day + "/b.png")).status, 200);
    assert.equal((await up(app, GAT(), "announcement-images", uuid() + "/1730000000000-a.png")).status, 403);
    assert.equal((await up(app, tokenFor("SADM - Quai2go", "carrier"), "receipts", day + "/q.png")).status, 403, "Quai2go has no receipts");
    const big = Buffer.concat([PNG, Buffer.alloc(8 * 1024 * 1024)]);
    assert.equal((await up(app, GAT(), "receipts", day + "/big.png", big)).status, 413);
    assert.equal((await up(app, GAT(), "receipts", "adjustments/" + day + "/a.png")).status, 200, "change-report photos: any signed-in user");
  } finally { await app.close(); }
});

test("receipts: carrier name comes from the session, URL must match, role is checked", async () => {
  const app = await boot();
  try {
    const day = "2026-11-04";
    await up(app, GAT(), "receipts", day + "/r.png");
    const row = { driver_name: "Jean", note: "Essence", storage_path: day + "/r.png", public_url: BASE + "/storage/v1/object/public/receipts/" + day + "/r.png", carrier_name: "FORGED", email_sent: true };
    const ok = await op(app, GAT(), { op: "receipt.insert", row });
    assert.equal(ok.status, 200);
    const { id } = await ok.json();
    const saved = await app.store.getReceipt(id);
    assert.equal(saved.carrier_name, "Gat - Sam");
    assert.equal(saved.email_sent, false);
    assert.equal((await op(app, GAT(), { op: "receipt.insert", row: { ...row, public_url: "https://evil.example/r.png" } })).status, 422);
    assert.equal((await op(app, GAT(), { op: "receipt.insert", row: { ...row, driver_name: "" } })).status, 400);
    assert.equal((await op(app, GAT(), { op: "receipt.insert", row: { ...row, storage_path: "bol/" + day + "/b.png", public_url: BASE + "/storage/v1/object/public/receipts/bol/" + day + "/b.png" } })).status, 403);
  } finally { await app.close(); }
});

test("change reports: validated, stored under the session carrier, no duplicates", async () => {
  const app = await boot();
  try {
    const id = uuid();
    const row = { id, order_num: "SO20179", order_kind: "SO", reporter_name: "Sam", items: [{ item: "Poteau", from: "8", to: "0" }], note: "n" };
    assert.equal((await op(app, GAT(), { op: "adjustment.insert", row })).status, 200);
    assert.equal((await app.store.getAdjustment(id)).carrier_name, "Gat - Sam");
    assert.equal((await op(app, GAT(), { op: "adjustment.insert", row })).status, 409);
    assert.equal((await op(app, GAT(), { op: "adjustment.insert", row: { ...row, id: uuid(), items: [] } })).status, 400);
    assert.equal((await op(app, GAT(), { op: "adjustment.insert", row: { ...row, id: uuid(), order_kind: "XX" } })).status, 400);
    assert.equal((await op(app, GAT(), { op: "adjustment.insert", row: { ...row, id: uuid(), photo_url: "https://evil.example/p.png" } })).status, 422);
    assert.equal((await op(app, GAT(), { op: "adjustment.insert", row: { ...row, id: "nope" } })).status, 400);
  } finally { await app.close(); }
});

test("delivery history: carriers write and read only their own names; SuperUser sees all", async () => {
  const app = await boot();
  try {
    const mk = (so, carrier, date) => ({ so_num: so, carrier_name: carrier, ship_date: date, customer: "C " + so, so_id: 1, bogus_column: "x" });
    const mine = await op(app, GAT(), { op: "history.upsert", rows: [mk("SO1", "Gat - Sam", "2026-11-02"), mk("SO2", "Other", "2026-11-02")] });
    assert.deepEqual(await mine.json(), { count: 1 }, "someone else's row is skipped");
    await op(app, SUPER(), { op: "history.upsert", rows: [mk("SO3", "Lindsay - Cole", "2026-11-03")] });
    const q = { op: "history.list", from: "2026-11-01", to: "2026-11-30" };
    const asGat = await (await op(app, GAT(), q)).json();
    assert.deepEqual(asGat.rows.map((r) => r.so_num), ["SO1"]);
    assert.equal("bogus_column" in asGat.rows[0], false);
    const asSuper = await (await op(app, SUPER(), q)).json();
    assert.deepEqual(asSuper.rows.map((r) => r.so_num).sort(), ["SO1", "SO3"]);
    assert.deepEqual((await (await op(app, SUPER(), { ...q, carrierNames: ["Lindsay - Cole"] })).json()).rows.map((r) => r.so_num), ["SO3"]);
    assert.equal((await op(app, GAT(), { op: "history.list", from: "bad", to: "2026-11-30" })).status, 400);
    assert.equal((await op(app, GAT(), { op: "history.upsert", rows: new Array(501).fill(mk("S", "Gat - Sam", "2026-11-02")) })).status, 400);
    assert.equal((await op(app, GAT(), { op: "nope" })).status, 404);
  } finally { await app.close(); }
});

async function seedReceipt(app, token, bol = false) {
  const day = "2026-11-04";
  const path = (bol ? "bol/" : "") + day + "/x.png";
  await up(app, token, "receipts", path);
  const { id } = await (await op(app, token, { op: "receipt.insert", row: { driver_name: "Jean", note: "", storage_path: path, public_url: BASE + "/storage/v1/object/public/receipts/" + path } })).json();
  return { id, path };
}
const mail = (app, token, body) =>
  fetch(app.url + "/functions/v1/send-transactional-email", { method: "POST", headers: { "Content-Type": "application/json", "X-Quai-Session": token }, body: JSON.stringify(body) });

test("email: receipt goes to accounting only, derived on the server; marks the row; is idempotent", async () => {
  const app = await boot();
  try {
    const { id, path } = await seedReceipt(app, GAT());
    const body = { templateName: "receipt-uploaded", idempotencyKey: "k1", recipientEmail: "attacker@evil.com", templateData: { kind: "receipt", receiptId: id, storagePath: path } };
    const r = await mail(app, GAT(), body);
    assert.equal(r.status, 200);
    assert.deepEqual(await r.json(), { success: true, queued: 1, duplicate: false });
    assert.equal(app.sent.length, 1);
    assert.equal(app.sent[0].to, "comptabilite@groupeql.com");
    assert.match(app.sent[0].subject, /Nouveau reçu — Jean \(Gat - Sam\)/);
    assert.match(app.sent[0].html, /Télécharger/);
    assert.match(app.sent[0].headers["List-Unsubscribe"], /unsubscribe\?token=/);
    assert.equal((await app.store.getReceipt(id)).email_sent, true);
    const again = await (await mail(app, GAT(), body)).json();
    assert.deepEqual(again, { success: true, queued: 0, duplicate: true });
    assert.equal(app.sent.length, 1, "same idempotency key never sends twice");
  } finally { await app.close(); }
});

test("email: guards (role, kind, other carrier's row, missing file, unknown template, key)", async () => {
  const app = await boot();
  try {
    const { id, path } = await seedReceipt(app, GAT());
    const data = { kind: "receipt", receiptId: id, storagePath: path };
    assert.equal((await mail(app, tokenFor("Lindsay - Cole", "carrier"), { templateName: "receipt-uploaded", idempotencyKey: "a", templateData: data })).status, 403, "not your receipt");
    assert.equal((await mail(app, GAT(), { templateName: "bol-uploaded", idempotencyKey: "b", templateData: { ...data, kind: "bol" } })).status, 403, "BOL role");
    assert.equal((await mail(app, GAT(), { templateName: "receipt-uploaded", idempotencyKey: "c", templateData: { ...data, kind: "bol" } })).status, 422);
    assert.equal((await mail(app, GAT(), { templateName: "receipt-uploaded", idempotencyKey: "d", templateData: { kind: "receipt", storagePath: "2026-11-04/none.png" } })).status, 404, "file must exist");
    assert.equal((await mail(app, GAT(), { templateName: "evil", idempotencyKey: "e", templateData: {} })).status, 404);
    assert.equal((await mail(app, GAT(), { templateName: "receipt-uploaded", templateData: data })).status, 400);
    assert.equal((await mail(app, "", { templateName: "receipt-uploaded", idempotencyKey: "f", templateData: data })).status, 401);
    assert.equal(app.sent.length, 0);
    // SuperUser may email on behalf of any carrier's receipt
    assert.equal((await mail(app, SUPER(), { templateName: "receipt-uploaded", idempotencyKey: "g", templateData: data })).status, 200);
  } finally { await app.close(); }
});

test("email: BOL goes to SADM; change report goes to the carrier's group, transfers to the stores", async () => {
  const app = await boot();
  try {
    const bol = await seedReceipt(app, LOGI(), true);
    assert.equal((await mail(app, LOGI(), { templateName: "bol-uploaded", idempotencyKey: "b1", templateData: { kind: "bol", receiptId: bol.id, storagePath: bol.path } })).status, 200);
    assert.equal(app.sent.at(-1).to, "sadm@groupeql.com");

    const id = uuid();
    await op(app, GAT(), { op: "adjustment.insert", row: { id, order_num: "SO1", order_kind: "SO", reporter_name: "Sam", items: [{ item: "<b>x</b>", from: "1", to: "2" }], note: "ok" } });
    assert.equal((await mail(app, GAT(), { templateName: "order-adjustment", idempotencyKey: "a1", templateData: { reportId: id } })).status, 200);
    assert.equal(app.sent.at(-1).to, "gatineau@groupeql.com");
    assert.match(app.sent.at(-1).html, /&lt;b&gt;x&lt;\/b&gt;/, "user text is HTML-escaped");
    assert.equal((await app.store.getAdjustment(id)).email_sent, true);
    assert.equal((await mail(app, tokenFor("Lindsay - Cole", "carrier"), { templateName: "order-adjustment", idempotencyKey: "a2", templateData: { reportId: id } })).status, 403);

    const to = uuid();
    await op(app, GAT(), { op: "adjustment.insert", row: { id: to, order_num: "TO9", order_kind: "TO", reporter_name: "Sam", items: [{ item: "x", from: "1", to: "2" }], note: "", transfer_locations: ["Gatineau", "Québec Ville"] } });
    const before = app.sent.length;
    assert.equal((await mail(app, GAT(), { templateName: "order-adjustment", idempotencyKey: "a3", templateData: { reportId: to } })).status, 200);
    assert.deepEqual(app.sent.slice(before).map((m) => m.to).sort(), ["gatineau@groupeql.com", "quebec@groupeql.com"]);
  } finally { await app.close(); }
});

test("email: unsubscribe suppresses future sends; hourly throttle; provider failure is retried then reported", async () => {
  const app = await boot();
  try {
    const { id, path } = await seedReceipt(app, GAT());
    const data = { kind: "receipt", receiptId: id, storagePath: path };
    await mail(app, GAT(), { templateName: "receipt-uploaded", idempotencyKey: "u1", templateData: data });
    const token = (await app.store.getUnsubscribeToken((await app.store.unsubscribeTokenFor("comptabilite@groupeql.com")))).email && (await app.store.unsubscribeTokenFor("comptabilite@groupeql.com"));
    const check = await (await fetch(app.url + "/functions/v1/handle-email-unsubscribe?token=" + token)).json();
    assert.deepEqual(check, { valid: true });
    const done = await fetch(app.url + "/functions/v1/handle-email-unsubscribe", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ token }) });
    assert.deepEqual(await done.json(), { success: true });
    const twice = await (await fetch(app.url + "/functions/v1/handle-email-unsubscribe", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ token }) })).json();
    assert.equal(twice.reason, "already_unsubscribed");
    assert.equal((await fetch(app.url + "/functions/v1/handle-email-unsubscribe?token=nope")).status, 404);
    assert.equal((await fetch(app.url + "/functions/v1/handle-email-unsubscribe")).status, 400);
    const sentBefore = app.sent.length;
    const sup = await (await mail(app, GAT(), { templateName: "receipt-uploaded", idempotencyKey: "u2", templateData: data })).json();
    assert.deepEqual(sup, { success: false, reason: "email_suppressed" });
    assert.equal(app.sent.length, sentBefore);
  } finally { await app.close(); }

  const t = await boot({ failSend: 3 });
  try {
    const { id, path } = await seedReceipt(t, GAT());
    const res = await mail(t, GAT(), { templateName: "receipt-uploaded", idempotencyKey: "f1", templateData: { kind: "receipt", receiptId: id, storagePath: path } });
    assert.equal(res.status, 502);
    assert.equal(t.store.sendLog.at(-1).status, "failed");
    assert.equal((await t.store.getReceipt(id)).email_sent, false, "not marked as emailed when sending failed");
    const retry = await mail(t, GAT(), { templateName: "receipt-uploaded", idempotencyKey: "f2", templateData: { kind: "receipt", receiptId: id, storagePath: path } });
    assert.equal(retry.status, 200);
  } finally { await t.close(); }

  const th = await boot();
  try {
    const { id, path } = await seedReceipt(th, GAT());
    for (let i = 0; i < 20; i++) th.store.sendLog.push({ metadata: { carrier: "Gat - Sam", idempotency_key: "x" + i }, status: "sent", created_at: new Date().toISOString() });
    const res = await mail(th, GAT(), { templateName: "receipt-uploaded", idempotencyKey: "t1", templateData: { kind: "receipt", receiptId: id, storagePath: path } });
    assert.equal(res.status, 429);
  } finally { await th.close(); }
});

test("CORS preflight, unknown data paths, oversized JSON", async () => {
  const app = await boot();
  try {
    const pre = await fetch(app.url + "/functions/v1/quai-data", { method: "OPTIONS" });
    assert.equal(pre.status, 204);
    assert.match(pre.headers.get("access-control-allow-headers"), /x-quai-session/);
    assert.equal((await fetch(app.url + "/functions/v1/other", { method: "POST", headers: { "X-Quai-Session": GAT() }, body: "{}" })).status, 404);
    assert.equal((await fetch(app.url + "/storage/v1/object/public/secrets/x.png")).status, 404);
    assert.equal((await fetch(app.url + "/storage/v1/object/public/receipts/%2e%2e/x")).status, 404);
    const huge = JSON.stringify({ op: "history.list", pad: "x".repeat(2 * 1024 * 1024 + 10) });
    const r = await fetch(app.url + "/functions/v1/quai-data", { method: "POST", headers: { "Content-Type": "application/json", "X-Quai-Session": GAT() }, body: huge });
    assert.equal(r.status, 413);
    assert.equal((await fetch(app.url + "/health")).status, 200);
  } finally { await app.close(); }
});

test("config: PUBLIC_BASE_URL is required with a database; email provider keys are checked", async () => {
  const { loadConfig } = await import("../src/config.js");
  const { makeEnv } = await import("./helpers.js");
  const e1 = loadConfig(makeEnv({ DATABASE_URL: "postgres://u:p@h/db" }));
  assert.ok(e1.errors.some((e) => e.includes("PUBLIC_BASE_URL")));
  const e2 = loadConfig(makeEnv({ DATABASE_URL: "postgres://u:p@h/db", PUBLIC_BASE_URL: BASE, EMAIL_PROVIDER: "resend" }));
  assert.ok(e2.errors.some((e) => e.includes("EMAIL_API_KEY")));
  const e3 = loadConfig(makeEnv({ DATABASE_URL: "postgres://u:p@h/db", PUBLIC_BASE_URL: BASE, EMAIL_PROVIDER: "resend", EMAIL_API_KEY: "k" }));
  assert.deepEqual(e3.errors, []);
  assert.equal(e3.config.data.store, "postgres");
  const e4 = loadConfig(makeEnv({}));
  assert.deepEqual(e4.errors, [], "without a database the server still starts (data API answers 503)");
  assert.ok(e4.warnings.some((w) => w.includes("DATABASE_URL")));
});

test("PgStore: parameterised SQL, fixed table names, upsert shape", async () => {
  const { PgStore } = await import("../src/data/store-pg.js");
  const calls = [];
  const pool = { query: async (text, params) => { calls.push({ text, params }); return { rows: [{ id: "id1", n: 0 }], rowCount: 1 }; } };
  const s = new PgStore(pool);
  await s.insertAnnouncement({ title: "t'; drop table x;--", body: "b", evil: "x" });
  assert.match(calls.at(-1).text, /insert into announcements \(title, body\) values \(\$1, \$2\)/);
  assert.deepEqual(calls.at(-1).params, ["t'; drop table x;--", "b"]);
  await s.updateAnnouncement("11111111-1111-1111-1111-111111111111", { title: "n", is_active: false });
  assert.match(calls.at(-1).text, /update announcements set title = \$1, updated_at = now\(\) where id = \$2/);
  await s.upsertHistory([{ so_num: "A", customer: "c" }, { so_num: "B" }]);
  assert.match(calls.at(-1).text, /on conflict \(so_num\) do update set/);
  assert.equal(calls.at(-1).params.length, 44);
  await s.listHistory({ from: "2026-01-01", to: "2026-02-01", carrierNames: ["a"], carrierIds: [1] });
  assert.match(calls.at(-1).text, /carrier_name = any\(\$3::text\[\]\) and carrier_id = any\(\$4::bigint\[\]\)/);
  await assert.rejects(() => s.markEmailSent("users; drop", "x"), /bad table/);
  await s.markEmailSent("receipts", "x");
  assert.match(calls.at(-1).text, /update receipts set email_sent = true where id = \$1/);
});
