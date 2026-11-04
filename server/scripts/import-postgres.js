// Imports an export made by export-supabase.js into the NEW Postgres. Rows are inserted with
// ON CONFLICT DO NOTHING, so running it twice is safe, and everything runs in ONE transaction. Picture links
// are rewritten from the old Supabase host to this server (NEW_BASE_URL = the same value as PUBLIC_BASE_URL).
//
//   DATABASE_URL=postgres://... NEW_BASE_URL=https://<railway-host> node scripts/import-postgres.js <exportDir> [--dry-run]
//
// NEVER run it against production without the owner's OK. --dry-run reads the export and prints counts only.
import { readFile, readdir, stat } from "node:fs/promises";
import { join } from "node:path";

const dir = process.argv[2];
const dry = process.argv.includes("--dry-run");
const newBase = (process.env.NEW_BASE_URL ?? "").replace(/\/+$/, "");
if (!dir) { console.error("usage: import-postgres.js <exportDir> [--dry-run]"); process.exit(1); }
if (!dry && (!process.env.DATABASE_URL || !newBase)) { console.error("DATABASE_URL and NEW_BASE_URL are required."); process.exit(1); }

const summary = JSON.parse(await readFile(join(dir, "summary.json"), "utf8"));
const oldBase = summary.sourceBase;
const rewrite = (v) => (typeof v === "string" && v.startsWith(oldBase) ? (newBase || "<NEW_BASE_URL>") + "/storage/v1/object/public/" + v.slice(oldBase.length) : v);
const load = async (t) => { try { return JSON.parse(await readFile(join(dir, t + ".json"), "utf8")); } catch { return []; } };

// Only columns that exist in db/schema.sql.
const COLS = {
  announcements: ["id", "title", "body", "title_fr", "body_fr", "is_active", "created_at", "updated_at"],
  announcement_images: ["id", "announcement_id", "storage_url", "created_at"],
  order_photos: ["id", "so_num", "storage_path", "uploaded_by", "created_at"],
  receipts: ["id", "created_at", "driver_name", "carrier_name", "note", "storage_path", "public_url", "email_sent"],
  order_adjustments: ["id", "created_at", "order_num", "order_kind", "carrier_name", "reporter_name", "items", "note", "photo_url", "transfer_locations", "email_sent"],
  delivery_history: ["so_num", "so_id", "customer", "service_type", "service_type_id", "status", "event_status", "ship_date", "event_start_date", "city", "state", "shipping_location_id", "shipping_location_name", "sale_location_id", "sale_location_name", "truck_id", "truck_name", "service_event_id", "service_event_name", "carrier_id", "carrier_name", "source", "created_at", "updated_at"],
  suppressed_emails: ["email", "reason", "created_at"],
  email_unsubscribe_tokens: ["email", "token", "used_at", "created_at"],
};
const CONFLICT = { delivery_history: "so_num", suppressed_emails: "email", email_unsubscribe_tokens: "email" };
const JSONB = new Set(["items", "transfer_locations"]);
const ORDER = ["announcements", "announcement_images", "order_photos", "receipts", "order_adjustments", "delivery_history", "suppressed_emails", "email_unsubscribe_tokens"];

let client = null;
if (!dry) {
  const { default: pg } = await import("pg");
  const { pgSsl } = await import("../src/data/pg-config.js");
  client = new pg.Client({ connectionString: process.env.DATABASE_URL, ssl: pgSsl(process.env.DATABASE_URL) });
  await client.connect();
  await client.query("begin");
}
try {
  for (const t of ORDER) {
    const rows = await load(t);
    let inserted = 0;
    if (!dry) {
      for (const r of rows) {
        const cols = COLS[t].filter((c) => r[c] !== undefined && r[c] !== null);
        const vals = cols.map((c) => (JSONB.has(c) ? JSON.stringify(r[c]) : rewrite(r[c])));
        const ph = cols.map((c, i) => "$" + (i + 1) + (JSONB.has(c) ? "::jsonb" : ""));
        const res = await client.query("insert into " + t + " (" + cols.join(",") + ") values (" + ph.join(",") + ") on conflict " + (CONFLICT[t] ? "(" + CONFLICT[t] + ") " : "") + "do nothing", vals);
        inserted += res.rowCount;
      }
    }
    console.log(t.padEnd(26), rows.length, "in export", dry ? "(dry run)" : inserted + " inserted");
  }
  let files = 0;
  async function walk(d, rel = []) {
    for (const name of await readdir(d)) {
      const p = join(d, name);
      if ((await stat(p)).isDirectory()) { await walk(p, [...rel, name]); continue; }
      if (name.endsWith(".type")) continue;
      const parts = [...rel, name];
      const bucket = parts[0];
      const path = parts.slice(1).join("/");
      let type = "application/octet-stream";
      try { type = (await readFile(p + ".type", "utf8")).split(";")[0].trim(); } catch { /* default */ }
      if (!dry) await client.query("insert into files (bucket, path, content_type, bytes) values ($1,$2,$3,$4) on conflict do nothing", [bucket, path, type, await readFile(p)]);
      files++;
    }
  }
  try { await walk(join(dir, "files")); } catch { /* no files exported */ }
  console.log("files".padEnd(26), files, dry ? "found (dry run)" : "imported");
  if (!dry) await client.query("commit");
} catch (e) {
  if (client) await client.query("rollback");
  console.error("import failed, rolled back:", e.message);
  process.exitCode = 1;
} finally {
  if (client) await client.end();
}
