// "Prepared" state of an order: one shared flag per order (+ service date), set by the logistics staff, read by
// everybody who can see the order. Routes (all need a signed-in session, see routes.js):
//   GET /prep-state?from=YYYY-MM-DD&to=YYYY-MM-DD   prepared orders of a date window (max 62 days)
//   GET /prep-state?orders=SO1,TO2                  prepared state of these orders, every date (max 300)
//   PUT /prep-state/:order   { prepared: bool, date?: "YYYY-MM-DD", label?: "Marc" }   logistique + superuser only
//   GET /prep-state/:order/history[?date=]           last changes (90 days), logistique + superuser only
//
// KEY = order number + service date (the calendar day of the card). The same order can sit on several days
// (delivery today, pick-up later); each day is prepared on its own, and an order moved to another day starts
// again as "to prepare". No date = one flag for the whole order (date stored as '').
//
// WHO: any session whose role is "logistique" (the exchange derives it from the roster: SADM - Logistique and every
// "<unit> - Logistique" entry) or "superuser". Carriers get read-only access to the orders they own.
import { HttpError } from "./handler.js";
import { ownsOrder } from "./orderChanges.js";

export const HISTORY_DAYS = 90;
export const STATE_DAYS = 180;
export const MAX_RANGE_DAYS = 62;
export const MAX_ORDERS = 300;
const ORDER_NUM = /^(SO|TO)\d{1,12}$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

export const canSetPrep = (s) => s.appRole === "logistique" || s.appRole === "superuser";
const cleanLabel = (v) => String(v ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, 40);

/** Strict (no trimming): "SO1\r\n" is refused. -> upper-cased number or throws 400. */
export function strictOrderNum(raw) {
  const n = String(raw ?? "").toUpperCase();
  if (!ORDER_NUM.test(n)) throw new HttpError(400, "order_num_invalid");
  return n;
}

export function validDate(d) {
  if (typeof d !== "string" || !DATE.test(d)) return false;
  const t = Date.parse(d + "T00:00:00Z");
  return !Number.isNaN(t) && new Date(t).toISOString().slice(0, 10) === d;
}

const dayDiff = (a, b) => Math.round((Date.parse(b + "T00:00:00Z") - Date.parse(a + "T00:00:00Z")) / 86_400_000);

export const publicState = (r) => ({
  orderNum: r.order_num, date: r.service_date ?? "", prepared: Boolean(r.prepared),
  by: r.updated_by ?? "", label: r.updated_label ?? "", at: r.updated_at instanceof Date ? r.updated_at.toISOString() : r.updated_at,
});

/** ctx: { store, now, log } */
export function createPrepState({ store, now = Date.now, log = () => {} }) {
  const staff = (s) => { if (!canSetPrep(s)) throw new HttpError(403, "role_not_allowed"); };
  let lastPrune = 0;
  async function prune() {
    const t = now();
    if (t - lastPrune < 3_600_000 || typeof store.prunePrep !== "function") return;
    lastPrune = t;
    try { await store.prunePrep(new Date(t - HISTORY_DAYS * 86_400_000).toISOString(), new Date(t - STATE_DAYS * 86_400_000).toISOString()); }
    catch (e) { log("prep_prune_failed", { message: e && e.message }); } // housekeeping never fails a request
  }

  async function list(params, s) {
    const ordersParam = params.get("orders");
    let rows;
    if (ordersParam !== null) {
      const nums = [...new Set(String(ordersParam).split(",").map((x) => x.toUpperCase()).filter((x) => ORDER_NUM.test(x)))].slice(0, MAX_ORDERS);
      rows = nums.length ? await store.listPrepStates({ nums }) : [];
    } else {
      const from = params.get("from"), to = params.get("to");
      if (!validDate(from) || !validDate(to) || to < from || dayDiff(from, to) >= MAX_RANGE_DAYS) throw new HttpError(400, "range_invalid");
      rows = await store.listPrepStates({ from, to });
    }
    if (!canSetPrep(s) && rows.length) { // carriers only learn about their own orders
      const hist = typeof store.getHistoryRows === "function" ? await store.getHistoryRows([...new Set(rows.map((r) => r.order_num))]) : [];
      const own = new Set(hist.filter((h) => ownsOrder(s, h)).map((h) => h.so_num));
      rows = rows.filter((r) => own.has(r.order_num));
    }
    return { states: rows.filter((r) => r.prepared).map(publicState), now: new Date(now()).toISOString() };
  }

  async function set(num, body, s) {
    staff(s);
    if (!body || typeof body !== "object" || typeof body.prepared !== "boolean") throw new HttpError(400, "prepared_required");
    const date = body.date === undefined || body.date === null || body.date === "" ? "" : body.date;
    if (date !== "" && !validDate(date)) throw new HttpError(400, "date_invalid");
    const label = cleanLabel(body.label);
    const out = await store.setPrepState({
      orderNum: num, date, prepared: body.prepared, actor: s.carrier, label, atIso: new Date(now()).toISOString(),
    });
    prune();
    // Idempotent: asking for the state the order already has changes nothing (no history row) and still answers 200.
    return { ...publicState(out.row), changed: out.changed };
  }

  async function history(num, params, s) {
    staff(s);
    const date = params.get("date");
    if (date !== null && date !== "" && !validDate(date)) throw new HttpError(400, "date_invalid");
    const since = new Date(now() - HISTORY_DAYS * 86_400_000).toISOString();
    const rows = await store.listPrepHistory(num, { date: date || null, sinceIso: since, limit: 50 });
    return {
      orderNum: num,
      history: rows.map((r) => ({ date: r.service_date ?? "", prepared: Boolean(r.prepared), by: r.actor, label: r.label ?? "", at: r.at instanceof Date ? r.at.toISOString() : r.at })),
    };
  }

  return { list, set, history };
}
