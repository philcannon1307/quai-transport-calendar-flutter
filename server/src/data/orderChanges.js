// "Order change notice": a change to a picking ticket is stored as an overlay in OUR Postgres (the job
// service / NetSuite expose no write endpoint), shown in the app as a "Changed" marker + history, and
// e-mailed to the right divisions. Routes (all need a signed-in session, see routes.js):
//   POST /orders/:num/changes          store the diff, resolve recipients, send the notice
//   POST /orders/:num/changes/preview  who WOULD be notified (nothing stored, nothing sent)
//   GET  /orders/:num/changes          history, newest first
//   GET  /orders/changed?nums=SO1,TO2  which of these orders carry changes (for the calendar badge)
//   GET|PUT /orders/division-contacts  SuperUser only: division -> mailboxes
import { createHash, randomUUID } from "node:crypto";
import { HttpError } from "./handler.js";
import { FALLBACK_INBOX, adjustmentInbox, isGroupeQl, isUuid, locationInbox } from "./guard.js";

export const DEFAULT_TEST_RECIPIENT = "communication@groupeql.com";
export const DEFAULT_DISPATCHER = "sadm@groupeql.com";
const ORDER_NUM = /^(SO|TO)\d{1,12}$/;
const KNOWN_FIELDS = new Set([
  "ship_date", "event_start_date", "truck", "carrier", "customer", "address", "phone", "city",
  "shipping_location", "receiving_location", "service_type", "status_note", "memo",
]);
const CUSTOM_FIELD = /^(item|custom):[^\u0000-\u001f]{1,70}$/;
const MAX_CHANGES = 40;
const MAX_VALUE = 500;
const DEDUPE_WINDOW_MS = 10 * 60_000;

/** Test-override setting. Defaults ON: unset => every notice goes to communication@groupeql.com. */
export function orderChangeSettings(env = {}) {
  const raw = env.TEST_RECIPIENT_OVERRIDE;
  const off = typeof raw === "string" && ["off", "false", "0", "none", "disabled"].includes(raw.trim().toLowerCase());
  const candidate = typeof raw === "string" && raw.trim() && !off ? raw.trim().toLowerCase() : DEFAULT_TEST_RECIPIENT;
  const dispatcher = (env.DISPATCHER_EMAIL || DEFAULT_DISPATCHER).trim().toLowerCase();
  const roles = String(env.ORDER_CHANGE_ROLES || "carrier,logistique,superuser").split(",").map((s) => s.trim()).filter(Boolean);
  const errors = [];
  if (!off && !isGroupeQl(candidate)) errors.push("TEST_RECIPIENT_OVERRIDE must be an @groupeql.com address (or 'off').");
  if (!isGroupeQl(dispatcher)) errors.push("DISPATCHER_EMAIL must be an @groupeql.com address.");
  return { errors, settings: { testOverride: off ? null : candidate, dispatcher, roles } };
}

const norm = (s) => String(s ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim();
const clean = (v, max) => String(v ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, max);

export function orderKindOf(num) { return num.startsWith("TO") ? "TO" : "SO"; }

export function validateOrderNum(raw) {
  const n = String(raw ?? "").trim().toUpperCase();
  if (!ORDER_NUM.test(n)) throw new HttpError(400, "order_num_invalid");
  return n;
}

/** Body -> { changes: [{field, old, new}], reason, context }. Throws HttpError(4xx). */
export function validateChange(body) {
  if (!body || typeof body !== "object" || !Array.isArray(body.changes)) throw new HttpError(400, "changes_required");
  if (body.changes.length > MAX_CHANGES) throw new HttpError(422, "too_many_changes");
  const seen = new Set();
  const changes = [];
  for (const c of body.changes) {
    if (!c || typeof c !== "object" || typeof c.field !== "string") throw new HttpError(400, "change_invalid");
    const field = c.field.trim();
    if (!KNOWN_FIELDS.has(field) && !CUSTOM_FIELD.test(field)) throw new HttpError(422, "field_not_allowed");
    if (seen.has(field)) throw new HttpError(422, "duplicate_field");
    seen.add(field);
    for (const k of ["old", "new"]) if (c[k] != null && (typeof c[k] !== "string" && typeof c[k] !== "number")) throw new HttpError(400, "change_invalid");
    const o = clean(c.old, MAX_VALUE), n = clean(c.new, MAX_VALUE);
    if (o === n) continue; // not a change
    changes.push({ field, old: o, new: n });
  }
  if (changes.length === 0) throw new HttpError(422, "no_changes");
  const ctx = body.context && typeof body.context === "object" ? body.context : {};
  const context = {};
  for (const k of ["shippingLocationName", "saleLocationName", "carrierName", "customer"]) if (typeof ctx[k] === "string" && ctx[k].trim()) context[k] = clean(ctx[k], 120);
  return { changes, reason: clean(body.reason, MAX_VALUE), context };
}

/** Location name -> { division, emails } using SuperUser-edited contacts first, then the built-in keyword map. */
export function resolveDivision(location, contacts = []) {
  const n = norm(location);
  if (!n) return null;
  for (const c of contacts) {
    const keys = [c.division, ...(Array.isArray(c.location_keywords) ? c.location_keywords : [])].map(norm).filter(Boolean);
    if (keys.some((k) => n.includes(k))) return { division: c.division, emails: (c.emails ?? []).map((e) => String(e).toLowerCase()).filter(isGroupeQl) };
  }
  const inbox = locationInbox(location);
  return inbox ? { division: inbox.split("@")[0], emails: [inbox] } : null;
}

/**
 * TO: creating division (from) + receiving division (to). SO: division it leaves from. Plus the carrier's
 * group inbox and the dispatcher. -> { recipients: [{email, roles[], division?}], unresolved: [..] }
 */
export function resolveRecipients({ kind, shippingLocation, receivingLocation, carrierName, contacts, dispatcher }) {
  const out = new Map();
  const unresolved = [];
  const add = (email, role, division) => {
    const e = String(email).toLowerCase();
    if (!isGroupeQl(e)) return;
    const cur = out.get(e) ?? { email: e, roles: [], division };
    if (!cur.roles.includes(role)) cur.roles.push(role);
    if (division && !cur.division) cur.division = division;
    out.set(e, cur);
  };
  const division = (loc, role) => {
    const d = resolveDivision(loc, contacts);
    if (!d || d.emails.length === 0) { unresolved.push(role + (loc ? ": " + loc : "")); return; }
    d.emails.forEach((e) => add(e, role, d.division));
  };
  if (kind === "TO") { division(shippingLocation, "creator"); division(receivingLocation, "receiver"); }
  else division(shippingLocation, "origin");
  if (carrierName) add(adjustmentInbox(carrierName), "carrier");
  if (dispatcher) add(dispatcher, "dispatcher");
  if (out.size === 0 || (unresolved.length && ![...out.values()].some((r) => r.roles.some((x) => ["creator", "receiver", "origin"].includes(x))))) add(FALLBACK_INBOX, "fallback");
  return { recipients: [...out.values()], unresolved };
}

export function requestHash(num, who, changes, reason) {
  return createHash("sha256").update(JSON.stringify([num, who, changes.map((c) => [c.field, c.old, c.new]), reason])).digest("hex");
}

async function orderContext(store, num, kind, ctx) {
  const row = typeof store.getHistoryRow === "function" ? await store.getHistoryRow(num) : null;
  return {
    shippingLocation: row?.shipping_location_name || ctx.shippingLocationName || "",
    receivingLocation: kind === "TO" ? (row?.sale_location_name || ctx.saleLocationName || "") : "",
    carrierName: row?.carrier_name || ctx.carrierName || "",
    customer: row?.customer || ctx.customer || "",
  };
}

/** Applies the override: delivered = [override] while it is on, otherwise the real list. */
export function deliveryPlan(recipients, settings) {
  const intended = recipients.map((r) => ({ email: r.email, roles: r.roles, division: r.division ?? null }));
  const override = settings.testOverride;
  return { intended, delivered: override ? [override] : intended.map((r) => r.email), override: Boolean(override) };
}

const publicChange = (r) => ({
  changeId: r.change_id, field: r.field, old: r.old_value, new: r.new_value, reason: r.reason,
  changedBy: r.changed_by, changedAt: r.changed_at, emailStatus: r.email_status,
});

/** ctx: { store, settings, sendEmail(changeId, session) -> {status, body}, now, log } */
export function createOrderChanges({ store, settings, sendEmail, now = Date.now, log = () => {} }) {
  const guardRole = (s) => { if (!settings.roles.includes(s.appRole)) throw new HttpError(403, "role_not_allowed"); };

  async function preview(num, body, s) {
    guardRole(s);
    const kind = orderKindOf(num);
    const ctx = body?.context && typeof body.context === "object" ? body.context : {};
    const c = await orderContext(store, num, kind, {
      shippingLocationName: clean(ctx.shippingLocationName, 120), saleLocationName: clean(ctx.saleLocationName, 120),
      carrierName: clean(ctx.carrierName, 120), customer: clean(ctx.customer, 120),
    });
    const contacts = typeof store.listDivisionContacts === "function" ? await store.listDivisionContacts() : [];
    const r = resolveRecipients({ kind, shippingLocation: c.shippingLocation, receivingLocation: c.receivingLocation, carrierName: c.carrierName, contacts, dispatcher: settings.dispatcher });
    const plan = deliveryPlan(r.recipients, settings);
    return { orderNum: num, orderKind: kind, recipients: plan.intended, deliveredTo: plan.delivered, testMode: plan.override, unresolved: r.unresolved };
  }

  async function create(num, body, s) {
    guardRole(s);
    const kind = orderKindOf(num);
    const { changes, reason, context } = validateChange(body);
    const hash = requestHash(num, s.carrier, changes, reason);
    const recent = await store.findRecentOrderChange(num, hash, new Date(now() - DEDUPE_WINDOW_MS).toISOString());
    if (recent) return { status: 200, body: { duplicate: true, changeId: recent.change_id, emailStatus: recent.email_status } };

    const c = await orderContext(store, num, kind, context);
    const contacts = typeof store.listDivisionContacts === "function" ? await store.listDivisionContacts() : [];
    const r = resolveRecipients({ kind, shippingLocation: c.shippingLocation, receivingLocation: c.receivingLocation, carrierName: c.carrierName, contacts, dispatcher: settings.dispatcher });
    const plan = deliveryPlan(r.recipients, settings);
    const changeId = randomUUID();
    const notified = { intended: plan.intended, delivered: plan.delivered, override: plan.override, unresolved: r.unresolved };
    await store.insertOrderChanges(changes.map((ch) => ({
      id: randomUUID(), change_id: changeId, order_num: num, order_kind: kind, field: ch.field, old_value: ch.old, new_value: ch.new,
      reason, changed_by: s.carrier, request_hash: hash,
      context: { carrierName: c.carrierName, shippingLocation: c.shippingLocation, receivingLocation: c.receivingLocation, customer: c.customer },
      notified_recipients: notified, email_status: "pending",
    })));

    let emailStatus = "failed";
    try {
      const out = await sendEmail(changeId, s);
      if (out.status === 200 && out.body?.success) emailStatus = plan.override ? "test_override" : "sent";
      else if (out.status === 200) emailStatus = "suppressed";
      else if (out.status === 429) emailStatus = "throttled";
      else emailStatus = "failed";
    } catch (e) {
      log("order_change_email_failed", { orderNum: num, code: e && e.code, message: e && e.message });
    }
    await store.setOrderChangeEmailStatus(changeId, emailStatus);
    return { status: 200, body: { changeId, orderNum: num, count: changes.length, emailStatus, testMode: plan.override, recipients: plan.intended, deliveredTo: plan.delivered } };
  }

  async function history(num) {
    const rows = await store.listOrderChanges(num);
    const byId = new Map();
    for (const r of rows) {
      const g = byId.get(r.change_id) ?? { changeId: r.change_id, changedBy: r.changed_by, changedAt: r.changed_at, reason: r.reason, emailStatus: r.email_status, fields: [] };
      g.fields.push({ field: r.field, old: r.old_value, new: r.new_value });
      byId.set(r.change_id, g);
    }
    return { orderNum: num, changed: byId.size > 0, changes: [...byId.values()] };
  }

  async function changedSummary(numsParam) {
    const nums = String(numsParam ?? "").split(",").map((x) => x.trim().toUpperCase()).filter((x) => ORDER_NUM.test(x)).slice(0, 300);
    return { changed: nums.length ? await store.changedSummary(nums) : {} };
  }

  const superOnly = (s) => { if (s.appRole !== "superuser") throw new HttpError(403, "superuser_only"); };
  async function listContacts(s) { superOnly(s); return { contacts: await store.listDivisionContacts() }; }
  async function putContact(body, s) {
    superOnly(s);
    const division = clean(body?.division, 60);
    const emails = Array.isArray(body?.emails) ? body.emails.map((e) => String(e).trim().toLowerCase()) : [];
    const keywords = Array.isArray(body?.locationKeywords) ? body.locationKeywords.map((k) => clean(k, 60)).filter(Boolean).slice(0, 20) : [];
    if (!division) throw new HttpError(400, "division_required");
    if (emails.length === 0 || emails.length > 10 || !emails.every(isGroupeQl)) throw new HttpError(422, "emails_invalid");
    await store.upsertDivisionContact({ division, emails, location_keywords: keywords, updated_by: s.carrier });
    return { ok: true };
  }

  return { preview, create, history, changedSummary, listContacts, putContact };
}

export { isUuid, publicChange };
