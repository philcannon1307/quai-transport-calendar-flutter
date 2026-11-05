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
import { normName } from "../roster.js";

export const DEFAULT_TEST_RECIPIENT = "communication@groupeql.com";
export const DEFAULT_DISPATCHER = "sadm@groupeql.com";
const ORDER_NUM = /^(SO|TO)\d{1,12}$/;
const KNOWN_FIELDS = new Set([
  "ship_date", "event_start_date", "truck", "carrier", "customer", "address", "phone", "city",
  "shipping_location", "receiving_location", "service_type", "status_note", "memo",
]);
const CUSTOM_FIELD = /^(item|custom):[^\u0000-\u001f]{1,70}$/;
const MAX_CHANGES = 40;
const MAX_LINES = 50;
const MAX_ITEM = 70;
const MAX_LINE_NOTE = 200;
const QTY = /^\d{1,6}$/;
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

const pad = (n) => String(n).padStart(2, "0");
const asText = (v) => {
  if (v == null) return "";
  if (v instanceof Date) return v.getFullYear() + "-" + pad(v.getMonth() + 1) + "-" + pad(v.getDate()); // pg DATE = local midnight
  return String(v);
};
// Ticket field -> delivery_history column. Only these "old" values can be trusted server-side.
const OLD_FROM_ROW = {
  ship_date: "ship_date", event_start_date: "event_start_date", truck: "truck_name", carrier: "carrier_name", customer: "customer",
  city: "city", shipping_location: "shipping_location_name", receiving_location: "sale_location_name", service_type: "service_type",
  status_note: "status",
};
/** The real value of a field as the server knows it, or undefined when the server has no data for it. */
export function serverOld(row, field) {
  const col = OLD_FROM_ROW[field];
  if (!row || !col || row[col] == null) return undefined;
  return clean(asText(row[col]), MAX_VALUE);
}

/** Quantity text/number -> non-negative integer string, or null when it is not one. */
function qtyOf(v) {
  if (typeof v === "number") return Number.isInteger(v) && v >= 0 && v <= 999999 ? String(v) : null;
  if (typeof v !== "string") return null;
  const t = v.trim();
  return QTY.test(t) ? String(Number(t)) : null;
}

/** Line-by-line mode: body.lines = [{ item, before, after, note }] (before blank/absent = 0 = added line). */
function validateLines(body) {
  if (!Array.isArray(body.lines)) throw new HttpError(400, "lines_invalid");
  if (body.lines.length > MAX_LINES) throw new HttpError(422, "too_many_changes");
  const seen = new Set();
  const changes = [];
  for (const l of body.lines) {
    if (!l || typeof l !== "object" || typeof l.item !== "string") throw new HttpError(400, "line_invalid");
    const item = clean(l.item, 200);
    if (!item || item.length > MAX_ITEM) throw new HttpError(422, "item_invalid");
    const key = norm(item);
    if (seen.has(key)) throw new HttpError(422, "duplicate_field");
    seen.add(key);
    const blank = l.before == null || (typeof l.before === "string" && l.before.trim() === "");
    const before = blank ? "0" : qtyOf(l.before);
    const after = qtyOf(l.after);
    if (before === null || after === null) throw new HttpError(422, "quantity_invalid");
    if (l.note != null && typeof l.note !== "string") throw new HttpError(400, "line_invalid");
    if (before === after) continue; // not a change
    changes.push({ field: "item:" + item, old: before, new: after, note: clean(l.note, MAX_LINE_NOTE) });
  }
  return changes;
}

/**
 * Body (+ the order's delivery_history row) -> { changes: [{field, old, new, note?}], reason }. Throws HttpError(4xx).
 * Current format: { lines: [{item, before, after, note}], reason } (a line = one "item:NAME" row; a note-only change is one "note" row).
 * Legacy format { changes: [{field, old, new}] } is still accepted.
 */
export function validateChange(body, row = null) {
  if (body && typeof body === "object" && body.lines !== undefined) {
    const changes = validateLines(body);
    const reason = clean(body.reason, MAX_VALUE);
    if (changes.length === 0 && !reason) throw new HttpError(422, "no_changes");
    if (changes.length === 0) changes.push({ field: "note", old: "", new: reason, note: "" });
    return { changes, reason };
  }
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
    const known = serverOld(row, field);
    const o = known !== undefined ? known : clean(c.old, MAX_VALUE), n = clean(c.new, MAX_VALUE);
    if (o === n) continue; // not a change
    changes.push({ field, old: o, new: n });
  }
  if (changes.length === 0) throw new HttpError(422, "no_changes");
  // body.context (locations, carrier) from the client is deliberately ignored: recipients come from server data only.
  return { changes, reason: clean(body.reason, MAX_VALUE) };
}

// ---- ownership: who may read / change which order
const tokensOf = (s) => norm(s).split(/[^a-z0-9]+/).filter(Boolean);
const BUILT_IN_WORDS = new Set(["sadm", "agathe", "gatineau", "lindsay", "laurier", "quebec", "sherbrooke", "estrie"]);
const hasSeq = (tokens, key) => {
  if (key.length === 0) return false;
  for (let i = 0; i + key.length <= tokens.length; i++) if (key.every((k, j) => tokens[i + j] === k)) return true;
  return false;
};

/**
 * "Own" order = the order's carrier (delivery_history.carrier_name) or truck (truck_name) is one of the names on the
 * session: the carrier's own login, its backend user and its linked trucks. Logistique (the SADM dispatcher, which
 * also sees the Gooseneck trucks) and SuperUser act on every order. No history row => nobody can prove ownership,
 * so a carrier is refused.
 */
export function ownsOrder(s, row) {
  if (s.appRole === "superuser" || s.appRole === "logistique") return true;
  if (!row) return false;
  const mine = new Set((Array.isArray(s.names) && s.names.length ? s.names : [s.carrier]).map(normName).filter(Boolean));
  return [row.carrier_name, row.truck_name].some((n) => n && mine.has(normName(n)));
}
const seesInternal = (s) => s.appRole === "superuser" || s.appRole === "logistique";

/** Location name -> { division, emails } using SuperUser-edited contacts first, then the built-in keyword map. */
export function resolveDivision(location, contacts = []) {
  const toks = tokensOf(location);
  if (toks.length === 0) return null;
  // whole words only: "Lindsay" matches the keyword "lindsay" but "Gat" or "ay" match nothing
  for (const c of contacts) {
    const keys = [c.division, ...(Array.isArray(c.location_keywords) ? c.location_keywords : [])].map(tokensOf).filter((k) => k.join("").length >= 3);
    if (keys.some((k) => hasSeq(toks, k))) return { division: c.division, emails: (c.emails ?? []).map((e) => String(e).toLowerCase()).filter(isGroupeQl) };
  }
  for (const t of toks) {
    const inbox = BUILT_IN_WORDS.has(t) ? locationInbox(t) : null;
    if (inbox) return { division: inbox.split("@")[0], emails: [inbox] };
  }
  return null;
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
  return createHash("sha256").update(JSON.stringify([num, who, changes.map((c) => [c.field, c.old, c.new, c.note ?? ""]), reason])).digest("hex");
}

/** Everything recipients depend on comes from our own delivery_history row; an unknown order yields empty values. */
function orderContext(row, kind) {
  return {
    shippingLocation: row?.shipping_location_name || "",
    receivingLocation: kind === "TO" ? (row?.sale_location_name || "") : "",
    carrierName: row?.carrier_name || "",
    customer: row?.customer || "",
  };
}

/** What a caller may see of a recipient list: staff see the mailboxes, carriers only roles and the division. */
export function maskPlan(plan, s) {
  if (seesInternal(s)) return { recipients: plan.intended, deliveredTo: plan.delivered };
  return { recipients: plan.intended.map((r) => ({ roles: r.roles, division: r.division })), deliveredTo: [] };
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

  async function loadOrder(num, s) {
    guardRole(s);
    const row = typeof store.getHistoryRow === "function" ? await store.getHistoryRow(num) : null;
    if (!ownsOrder(s, row)) throw new HttpError(403, "not_your_order");
    return row;
  }

  async function planFor(num, row) {
    const kind = orderKindOf(num);
    const c = orderContext(row, kind);
    const contacts = typeof store.listDivisionContacts === "function" ? await store.listDivisionContacts() : [];
    const r = resolveRecipients({ kind, shippingLocation: c.shippingLocation, receivingLocation: c.receivingLocation, carrierName: c.carrierName, contacts, dispatcher: settings.dispatcher });
    if (!row && !r.unresolved.includes("order: unknown")) r.unresolved.push("order: unknown"); // not in our data: dispatcher + fallback only
    return { kind, c, r, plan: deliveryPlan(r.recipients, settings) };
  }

  async function preview(num, body, s) {
    const row = await loadOrder(num, s);
    const { kind, r, plan } = await planFor(num, row);
    const m = maskPlan(plan, s);
    return { orderNum: num, orderKind: kind, recipients: m.recipients, deliveredTo: m.deliveredTo, testMode: plan.override, unresolved: seesInternal(s) ? r.unresolved : r.unresolved.length ? ["division"] : [] };
  }

  async function create(num, body, s) {
    const row = await loadOrder(num, s);
    const { changes, reason } = validateChange(body, row);
    const hash = requestHash(num, s.carrier, changes, reason);
    const { kind, c, r, plan } = await planFor(num, row);
    const changeId = randomUUID();
    const notified = { intended: plan.intended, delivered: plan.delivered, override: plan.override, unresolved: r.unresolved };
    const rec = await store.recordOrderChange(changes.map((ch) => ({
      id: randomUUID(), change_id: changeId, order_num: num, order_kind: kind, field: ch.field, old_value: ch.old, new_value: ch.new,
      reason, changed_by: s.carrier, request_hash: hash,
      context: { carrierName: c.carrierName, shippingLocation: c.shippingLocation, receivingLocation: c.receivingLocation, customer: c.customer, ...(ch.note ? { lineNote: ch.note } : {}) },
      notified_recipients: notified, email_status: "pending",
    })), { orderNum: num, hash, sinceIso: new Date(now() - DEDUPE_WINDOW_MS).toISOString() });
    if (rec.duplicate) {
      // Nothing is stored or mailed again. testMode tells the app which wording to use (same value as a fresh send).
      const dm = maskPlan(plan, s);
      return { status: 200, body: { duplicate: true, changeId: rec.duplicate.change_id, orderNum: num, emailStatus: rec.duplicate.email_status, testMode: plan.override, recipients: dm.recipients, deliveredTo: dm.deliveredTo } };
    }

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
    const m = maskPlan(plan, s);
    return { status: 200, body: { changeId, orderNum: num, count: changes.length, emailStatus, testMode: plan.override, recipients: m.recipients, deliveredTo: m.deliveredTo } };
  }

  async function history(num, s) {
    await loadOrder(num, s);

    const rows = await store.listOrderChanges(num);
    const byId = new Map();
    for (const r of rows) {
      const g = byId.get(r.change_id) ?? { changeId: r.change_id, changedBy: r.changed_by, changedAt: r.changed_at, reason: r.reason, emailStatus: r.email_status, fields: [] };
      g.fields.push({ field: r.field, old: r.old_value, new: r.new_value, ...(r.context?.lineNote ? { note: r.context.lineNote } : {}) });
      byId.set(r.change_id, g);
    }
    return { orderNum: num, changed: byId.size > 0, changes: [...byId.values()] };
  }

  async function changedSummary(numsParam, s) {
    guardRole(s);
    let nums = [...new Set(String(numsParam ?? "").split(",").map((x) => x.trim().toUpperCase()).filter((x) => ORDER_NUM.test(x)))].slice(0, 300);
    if (!seesInternal(s) && nums.length) { // carriers only learn about their own orders
      const rows = typeof store.getHistoryRows === "function" ? await store.getHistoryRows(nums) : [];
      const own = new Set(rows.filter((row) => ownsOrder(s, row)).map((row) => row.so_num));
      nums = nums.filter((n) => own.has(n));
    }
    return { changed: nums.length ? await store.changedSummary(nums) : {} };
  }

  const superOnly = (s) => { if (s.appRole !== "superuser") throw new HttpError(403, "superuser_only"); };
  async function listContacts(s) { superOnly(s); return { contacts: await store.listDivisionContacts() }; }
  async function putContact(body, s) {
    superOnly(s);
    const division = clean(body?.division, 60);
    const emails = Array.isArray(body?.emails) ? body.emails.map((e) => String(e).trim().toLowerCase()) : [];
    const keywords = Array.isArray(body?.locationKeywords) ? body.locationKeywords.map((k) => clean(k, 60)).filter((k) => k.length >= 3).slice(0, 20) : [];
    if (!division) throw new HttpError(400, "division_required");
    if (emails.length === 0 || emails.length > 10 || !emails.every(isGroupeQl)) throw new HttpError(422, "emails_invalid");
    await store.upsertDivisionContact({ division, emails, location_keywords: keywords, updated_by: s.carrier });
    return { ok: true };
  }

  return { preview, create, history, changedSummary, listContacts, putContact };
}

export { isUuid, publicChange };
