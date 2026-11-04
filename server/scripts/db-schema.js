// Applies db/schema.sql to DATABASE_URL. Idempotent. NEVER run it against production without the owner's OK.
//   DATABASE_URL=postgres://... node scripts/db-schema.js          (add --dry-run to only print what would run)
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const file = fileURLToPath(new URL("../db/schema.sql", import.meta.url));
const sql = await readFile(file, "utf8");
if (process.argv.includes("--dry-run")) {
  console.log(sql);
  console.log("-- dry run: nothing executed");
  process.exit(0);
}
if (!process.env.DATABASE_URL) { console.error("DATABASE_URL is required."); process.exit(1); }
const { default: pg } = await import("pg");
const local = /railway\.internal|localhost|127\.0\.0\.1/.test(process.env.DATABASE_URL);
const client = new pg.Client({ connectionString: process.env.DATABASE_URL, ssl: local ? undefined : { rejectUnauthorized: false } });
await client.connect();
try { await client.query(sql); console.log("schema applied"); } finally { await client.end(); }
