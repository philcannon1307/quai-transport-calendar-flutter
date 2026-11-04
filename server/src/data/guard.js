// Authorization helpers for the data API. Port of supabase/functions/quai-data/guard.ts.
// The session itself is verified by jwt.js (same HS256 token the exchange mints); this file turns the
// verified claims into a Session and holds the role rules, inbox routing and path validators.
import { verifySession as verifyJwt } from "../jwt.js";

/** Claims -> { carrier, uid, appRole, exp, names } or null. */
export function sessionFromToken(token, secret, nowMs = Date.now()) {
  const p = verifyJwt(token, secret, nowMs);
  if (!p) return null;
  if (!["carrier", "logistique", "superuser"].includes(p.app_role)) return null;
  if (typeof p.carrier !== "string" || !p.carrier || typeof p.sub !== "string" || !p.sub) return null;
  const names = Array.isArray(p.names) ? p.names.filter((n) => typeof n === "string") : [];
  return { carrier: p.carrier, uid: p.sub, appRole: p.app_role, exp: p.exp, names };
}

/** Token from X-Quai-Session, else "Authorization: Bearer" (the app can send either). */
export function sessionTokenFrom(headers) {
  const x = headers["x-quai-session"];
  if (x) return String(x);
  const a = String(headers["authorization"] ?? "");
  return a.toLowerCase().startsWith("bearer ") ? a.slice(7).trim() : null;
}

const ALIAS_GROUP = [
  ["SADM - David", "SADM"], ["SADM - Éric", "SADM"], ["SADM - Jayson", "SADM"], ["SADM - Mathieu", "SADM"],
  ["SADM - Quai2go", "SADM"], ["SADM - Steve", "SADM"], ["Gat - Sam", "Gatineau"],
  ["Lindsay - Brendan", "Lindsay"], ["Lindsay - Cole", "Lindsay"], ["Lindsay - Laurent", "Lindsay"],
  ["Mt-Laurier - Steve", "Mt-Laurier"], ["Québec - Justin", "Québec"], ["Québec - Marc", "Québec"],
  ["Sherbrooke - Hervé", "Sherbrooke"], ["InterQL", "Gooseneck"], ["RIDEAU GOOSENECK", "Gooseneck"],
  ["OPEN GOOSENECK", "Gooseneck"], ["DA TRANSPORT", "Externe"], ["LANCEZ TRANSPORT", "Externe"],
  ["SD PRESTIGE", "Externe"], ["SADM - Logistique", "SADM"],
];
const GROUP_INBOX = {
  SADM: "sadm@groupeql.com", Gooseneck: "sadm@groupeql.com", Gatineau: "gatineau@groupeql.com",
  Lindsay: "lindsay@groupeql.com", "Mt-Laurier": "mt-laurier@groupeql.com", Québec: "quebec@groupeql.com",
  Externe: "quebec@groupeql.com", Sherbrooke: "estrie@groupeql.com",
};
export const FALLBACK_INBOX = "comptabilite@groupeql.com";
export const RECEIPT_INBOX = "comptabilite@groupeql.com";
export const BOL_INBOX = "sadm@groupeql.com";

/** Verbatim from lib/logic/receipts_policy.dart. "SADM - Quai2go" is deliberately absent. */
export const RECEIPTS_ALLOWED = new Set([
  "SADM - David", "SADM - Éric", "SADM - Jayson", "SADM - Mathieu", "SADM - Steve", "Gat - Sam", "InterQL",
  "Lindsay - Brendan", "Lindsay - Cole", "Lindsay - Laurent", "Mt-Laurier - Steve", "Québec - Justin",
  "Québec - Marc", "Sherbrooke - Hervé", "SADM - Logistique",
]);

export const canUploadReceipt = (s) => s.appRole === "superuser" || RECEIPTS_ALLOWED.has(s.carrier);
export const canUploadBol = (s) => s.appRole === "logistique" || s.appRole === "superuser";

export function adjustmentInbox(carrierName) {
  const hit = ALIAS_GROUP.find(([n]) => n === carrierName);
  return (hit && GROUP_INBOX[hit[1]]) || FALLBACK_INBOX;
}

/** Store inbox for a NetSuite location name (only ever one of OUR fixed addresses). */
export function locationInbox(location) {
  const n = String(location).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
  if (/agathe|sadm/.test(n)) return GROUP_INBOX.SADM;
  if (n.includes("gatineau")) return GROUP_INBOX.Gatineau;
  if (n.includes("lindsay")) return GROUP_INBOX.Lindsay;
  if (n.includes("laurier")) return GROUP_INBOX["Mt-Laurier"];
  if (n.includes("quebec")) return GROUP_INBOX["Québec"];
  if (/sherbrooke|estrie/.test(n)) return GROUP_INBOX.Sherbrooke;
  return null;
}

/** Change reports: transfers go to the stores involved; otherwise the carrier's group inbox. */
export function adjustmentRecipients(carrierName, transferLocations = []) {
  const stores = transferLocations.map(locationInbox).filter(Boolean);
  const list = stores.length ? stores : [adjustmentInbox(carrierName)];
  return [...new Set(list)];
}

export const isGroupeQl = (email) => /^[^@\s]+@groupeql\.com$/i.test(String(email).trim());
export const isUuid = (s) => typeof s === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);

const FILE = "[A-Za-z0-9._-]{1,120}";
const RECEIPT_PATH = new RegExp("^[0-9]{4}-[0-9]{2}-[0-9]{2}/" + FILE + "$");
const BOL_PATH = new RegExp("^bol/[0-9]{4}-[0-9]{2}-[0-9]{2}/" + FILE + "$");
export const validReceiptPath = (p) => typeof p === "string" && RECEIPT_PATH.test(p);
export const validBolPath = (p) => typeof p === "string" && BOL_PATH.test(p);

export const encodePath = (p) => p.split("/").map(encodeURIComponent).join("/");
