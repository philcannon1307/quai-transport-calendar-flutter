// Data operations of the Flutter app. Port of supabase/functions/quai-data/handler.ts: the same op
// names, the same validation and the same authorization rules, now talking to the store directly.
import { canUploadBol, canUploadReceipt, encodePath, isUuid, validBolPath, validReceiptPath } from "./guard.js";

export const MAX_JSON_BYTES = 2 * 1024 * 1024;
export const MAX_UPLOAD_BYTES = 8 * 1024 * 1024;
export const UPLOAD_TYPES = ["image/jpeg", "image/png", "image/webp"];
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const FILE = "[A-Za-z0-9._-]{1,200}";
const ANNOUNCEMENT_PATH = new RegExp("^[0-9a-fA-F-]{36}/[0-9]{9,16}-" + FILE + "$");
const ADJUSTMENT_PATH = new RegExp("^adjustments/[0-9]{4}-[0-9]{2}-[0-9]{2}/" + FILE + "$");

export class HttpError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
export const deny = (status, code) => { throw new HttpError(status, code); };

/** The bytes must really be the picture type the caller claims (no html/svg/script uploads). */
export function looksLike(type, b) {
  const at = (i, s) => [...s].every((c, k) => b[i + k] === c.charCodeAt(0));
  if (type === "image/jpeg") return b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
  if (type === "image/png") return b[0] === 0x89 && at(1, "PNG");
  if (type === "image/webp") return at(0, "RIFF") && at(8, "WEBP");
  return false;
}

const str = (v, max, field, required = false) => {
  if (v === undefined || v === null) { if (required) deny(400, field + "_required"); return ""; }
  if (typeof v !== "string" || v.length > max) deny(400, field + "_invalid");
  if (required && !v.trim()) deny(400, field + "_required");
  return v;
};

const isSuper = (s) => s.appRole === "superuser";
const needSuper = (s) => { if (!isSuper(s)) deny(403, "superuser_only"); };

/** Base of the public file URLs, e.g. https://<railway>/storage/v1/object/public/<bucket> */
export const publicBase = (baseUrl, bucket) => baseUrl + "/storage/v1/object/public/" + bucket;

const ANNOUNCEMENT_FIELDS = [["title", 200], ["body", 8000], ["title_fr", 200], ["body_fr", 8000]];
function announcementRow(input, requireAll) {
  if (!input || typeof input !== "object") deny(400, "row_required");
  const row = {};
  for (const [k, max] of ANNOUNCEMENT_FIELDS) {
    if (input[k] === undefined) { if (requireAll && (k === "title" || k === "body")) deny(400, k + "_required"); continue; }
    row[k] = str(input[k], max, k, k === "title" || k === "body");
  }
  return row;
}

const HISTORY_COLUMNS = [
  "so_num", "so_id", "customer", "service_type", "service_type_id", "status", "event_status", "ship_date", "event_start_date",
  "city", "state", "shipping_location_id", "shipping_location_name", "sale_location_id", "sale_location_name", "truck_id",
  "truck_name", "service_event_id", "service_event_name", "carrier_id", "carrier_name", "source",
];
const scalar = (v) => v === null || typeof v === "number" || typeof v === "boolean" || (typeof v === "string" && v.length <= 300);

/** Upload a picture. query: { bucket, path }; bytes: Buffer; type: content-type. */
export async function upload({ bucket, path, type, bytes }, s, store, baseUrl) {
  if (bucket === "announcement-images") {
    needSuper(s);
    if (!ANNOUNCEMENT_PATH.test(path)) deny(422, "bad_path");
  } else if (bucket === "receipts") {
    if (ADJUSTMENT_PATH.test(path)) { /* any signed-in app user */ }
    else if (validBolPath(path)) { if (!canUploadBol(s)) deny(403, "role_not_allowed"); }
    else if (validReceiptPath(path)) { if (!canUploadReceipt(s)) deny(403, "role_not_allowed"); }
    else deny(422, "bad_path");
  } else deny(422, "bad_bucket");
  if (!UPLOAD_TYPES.includes(type)) deny(415, "unsupported_type");
  if (bytes.length === 0) deny(400, "empty_file");
  if (bytes.length > MAX_UPLOAD_BYTES) deny(413, "too_large");
  if (!looksLike(type, bytes)) deny(415, "content_mismatch");
  if (!(await store.putFile(bucket, path, type, bytes))) deny(409, "already_exists");
  return { url: publicBase(baseUrl, bucket) + "/" + encodePath(path) };
}

const inRange = (b) => ({ from: b.from, to: b.to });

/** One JSON op. s = verified session. */
export async function run(op, b, s, store, baseUrl) {
  switch (op) {
    // --- announcements: SuperUser only ----------------------------------------------------------
    case "announcement.insert": {
      needSuper(s);
      return { id: await store.insertAnnouncement(announcementRow(b.row, true)) };
    }
    case "announcement.update": {
      needSuper(s);
      if (!isUuid(b.id)) deny(400, "id_invalid");
      await store.updateAnnouncement(b.id, announcementRow(b.row, false));
      return {};
    }
    case "announcement.delete": {
      needSuper(s);
      if (!isUuid(b.id)) deny(400, "id_invalid");
      await store.deleteAnnouncement(b.id);
      return {};
    }
    case "announcement.image.add": {
      needSuper(s);
      if (!isUuid(b.announcementId)) deny(400, "announcementId_invalid");
      const u = str(b.url, 600, "url", true);
      if (!u.startsWith(publicBase(baseUrl, "announcement-images") + "/")) deny(422, "bad_url");
      await store.addAnnouncementImage(b.announcementId, u);
      return {};
    }
    case "announcement.image.remove": {
      needSuper(s);
      const u = str(b.url, 600, "url", true);
      if (!u.startsWith(publicBase(baseUrl, "announcement-images") + "/")) deny(422, "bad_url");
      await store.removeAnnouncementImage(u);
      return {};
    }
    case "files.remove": {
      needSuper(s);
      if (b.bucket !== "announcement-images") deny(422, "bad_bucket");
      const paths = b.paths;
      if (!Array.isArray(paths) || paths.length === 0 || paths.length > 20 || !paths.every((p) => typeof p === "string" && ANNOUNCEMENT_PATH.test(p))) deny(422, "bad_path");
      await store.deleteFiles("announcement-images", paths);
      return {};
    }

    // --- receipts / BOL log ---------------------------------------------------------------------
    case "receipt.insert": {
      const r = b.row;
      if (!r || typeof r !== "object") deny(400, "row_required");
      const path = r.storage_path;
      const isBol = validBolPath(path);
      if (!isBol && !validReceiptPath(path)) deny(422, "bad_storage_path");
      if (isBol ? !canUploadBol(s) : !canUploadReceipt(s)) deny(403, "role_not_allowed");
      const url = publicBase(baseUrl, "receipts") + "/" + encodePath(path);
      if (r.public_url !== url) deny(422, "bad_url");
      const id = await store.insertReceipt({
        driver_name: str(r.driver_name, 120, "driver_name", true), note: str(r.note, 2000, "note"),
        storage_path: path, public_url: url,
        carrier_name: s.carrier, // from the verified session, never from the body
      });
      return { id: id ?? null };
    }

    // --- change reports ---------------------------------------------------------------------------
    case "adjustment.insert": {
      const r = b.row;
      if (!r || typeof r !== "object") deny(400, "row_required");
      if (!isUuid(r.id)) deny(400, "id_invalid");
      if (r.order_kind !== "SO" && r.order_kind !== "TO") deny(400, "order_kind_invalid");
      if (!Array.isArray(r.items) || r.items.length === 0 || r.items.length > 50 || JSON.stringify(r.items).length > 20000) deny(400, "items_invalid");
      let photo = null;
      if (r.photo_url !== undefined && r.photo_url !== null) {
        photo = str(r.photo_url, 600, "photo_url");
        if (!photo.startsWith(publicBase(baseUrl, "receipts") + "/adjustments/")) deny(422, "bad_url");
      }
      let locations = null;
      if (r.order_kind === "TO" && r.transfer_locations !== undefined && r.transfer_locations !== null) {
        const t = r.transfer_locations;
        if (!Array.isArray(t) || t.length > 4 || !t.every((x) => typeof x === "string" && x.length <= 80)) deny(400, "transfer_locations_invalid");
        locations = t;
      }
      const ok = await store.insertAdjustment({
        id: r.id, order_num: str(r.order_num, 40, "order_num", true), order_kind: r.order_kind,
        reporter_name: str(r.reporter_name, 120, "reporter_name"), items: r.items, note: str(r.note, 4000, "note"),
        photo_url: photo, transfer_locations: locations,
        carrier_name: s.carrier, // from the verified session, never from the body
      });
      if (!ok) deny(409, "already_exists");
      return { id: r.id };
    }

    // --- delivery history ---------------------------------------------------------------------------
    case "history.upsert": {
      const rows = b.rows;
      if (!Array.isArray(rows) || rows.length > 500) deny(400, "rows_invalid");
      const mine = new Set(s.names);
      const bySo = new Map();
      for (const r of rows) {
        if (!r || typeof r !== "object") continue;
        const so = r.so_num;
        if (typeof so !== "string" || !so || so.length > 40) continue;
        if (!isSuper(s) && !(typeof r.carrier_name === "string" && mine.has(r.carrier_name))) continue; // not yours: skipped
        const clean = {};
        for (const k of HISTORY_COLUMNS) {
          const v = r[k];
          clean[k] = v === undefined || !scalar(v) ? null : v;
        }
        clean.source = typeof r.source === "string" && r.source ? r.source : "app";
        bySo.set(so, clean);
      }
      if (bySo.size === 0) return { count: 0 };
      await store.upsertHistory([...bySo.values()]);
      return { count: bySo.size };
    }
    case "history.list": {
      if (typeof b.from !== "string" || !DATE.test(b.from) || typeof b.to !== "string" || !DATE.test(b.to)) deny(400, "range_invalid");
      const okList = (xs, f) => Array.isArray(xs) && xs.length <= 50 && xs.every(f);
      if (b.carrierNames !== undefined && !okList(b.carrierNames, (n) => typeof n === "string" && n.length <= 80)) deny(400, "carrierNames_invalid");
      if (b.carrierIds !== undefined && !okList(b.carrierIds, (n) => Number.isInteger(n))) deny(400, "carrierIds_invalid");
      const q = inRange(b);
      const asked = b.carrierNames && b.carrierNames.length ? b.carrierNames : undefined;
      if (!isSuper(s)) {
        // a carrier only ever sees rows labelled with the names its login covers
        const allowed = asked ? s.names.filter((n) => asked.includes(n)) : s.names;
        if (allowed.length === 0) return { rows: [] };
        q.carrierNames = allowed;
      } else if (asked && !(b.carrierIds && b.carrierIds.length)) {
        q.carrierNames = asked;
      }
      if (b.carrierIds && b.carrierIds.length) q.carrierIds = b.carrierIds;
      return { rows: await store.listHistory(q) };
    }
  }
  return deny(404, "unknown_op");
}
