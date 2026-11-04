// Exports the OLD Supabase / Lovable Cloud project to a local folder (JSON + pictures). READ-ONLY on the
// old project: only GET requests. Run it BEFORE the old project is locked down.
//
//   SUPABASE_URL=https://<ref>.supabase.co SUPABASE_KEY=<anon or service key> node scripts/export-supabase.js [outDir]
//
// The key is read from the environment only (never a CLI argument, never logged). With the public (anon)
// key it can read what the old policies allow; the owner can pass a service key from their own shell.
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const url = (process.env.SUPABASE_URL ?? "").replace(/\/+$/, "");
const key = process.env.SUPABASE_KEY ?? "";
const out = process.argv[2] || "export-supabase";
if (!url || !key) { console.error("SUPABASE_URL and SUPABASE_KEY are required."); process.exit(1); }

const TABLES = [
  "announcements", "announcement_images", "order_photos", "receipts", "order_adjustments", "delivery_history",
  "email_send_log", "suppressed_emails", "email_unsubscribe_tokens",
];
const PAGE = 1000;
const headers = { apikey: key, Authorization: "Bearer " + key };

async function getJson(path) {
  const res = await fetch(url + path, { headers });
  if (!res.ok) throw new Error(path.split("?")[0] + " -> HTTP " + res.status);
  return res.json();
}

await mkdir(join(out, "files"), { recursive: true });
const summary = { exportedAt: new Date().toISOString(), source: url, tables: {}, files: { ok: 0, failed: [] } };

for (const t of TABLES) {
  try {
    const rows = [];
    const orderBy = t === "delivery_history" ? "so_num" : t === "suppressed_emails" || t === "email_unsubscribe_tokens" ? "email" : "created_at";
    for (let from = 0; ; from += PAGE) {
      const page = await getJson("/rest/v1/" + t + "?select=*&order=" + orderBy + ".asc&limit=" + PAGE + "&offset=" + from);
      rows.push(...page);
      if (page.length < PAGE) break;
    }
    await writeFile(join(out, t + ".json"), JSON.stringify(rows, null, 1));
    summary.tables[t] = rows.length;
    console.log(t.padEnd(26), rows.length, "rows");
  } catch (e) {
    summary.tables[t] = "ERROR " + e.message;
    console.log(t.padEnd(26), "skipped:", e.message);
  }
}

// Pictures: every public URL found in the rows is downloaded (the buckets are public).
const prefix = url + "/storage/v1/object/public/";
const urls = new Set();
const grab = (v) => { if (typeof v === "string" && v.startsWith(prefix)) urls.add(v); };
for (const t of ["announcement_images", "receipts", "order_adjustments"]) {
  try {
    const rows = JSON.parse(await readFile(join(out, t + ".json"), "utf8"));
    for (const r of rows) { grab(r.storage_url); grab(r.public_url); grab(r.photo_url); }
  } catch { /* table skipped */ }
}
for (const u of urls) {
  const rel = u.slice(prefix.length); // <bucket>/<path>
  try {
    const res = await fetch(u);
    if (!res.ok) throw new Error("HTTP " + res.status);
    const parts = rel.split("/").map(decodeURIComponent);
    if (parts.some((p) => p === ".." || p === "")) throw new Error("unsafe path");
    const dest = join(out, "files", ...parts);
    await mkdir(join(dest, ".."), { recursive: true });
    await writeFile(dest, Buffer.from(await res.arrayBuffer()));
    await writeFile(dest + ".type", res.headers.get("content-type") ?? "application/octet-stream");
    summary.files.ok++;
  } catch (e) { summary.files.failed.push(rel + " (" + e.message + ")"); }
}
summary.sourceBase = prefix;
await writeFile(join(out, "summary.json"), JSON.stringify(summary, null, 2));
console.log("files:", summary.files.ok, "downloaded,", summary.files.failed.length, "failed");
console.log("written to", out);
