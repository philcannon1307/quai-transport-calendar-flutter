// Postgres store (node-postgres). Every query is parameterised; table and column names are fixed in
// this file, never taken from a request.
const HISTORY_COLUMNS = [
  "so_num", "so_id", "customer", "service_type", "service_type_id", "status", "event_status", "ship_date",
  "event_start_date", "city", "state", "shipping_location_id", "shipping_location_name", "sale_location_id",
  "sale_location_name", "truck_id", "truck_name", "service_event_id", "service_event_name", "carrier_id",
  "carrier_name", "source",
];

export class PgStore {
  /** pool: anything with query(text, params) -> { rows, rowCount } (a pg.Pool in production). */
  constructor(pool) { this.pool = pool; }

  async q(text, params = []) { return this.pool.query(text, params); }
  async ping() { await this.q("select 1"); return true; }

  // announcements
  async insertAnnouncement(row) {
    const keys = Object.keys(row).filter((k) => ["title", "body", "title_fr", "body_fr", "is_active"].includes(k));
    const cols = keys.join(", ");
    const ph = keys.map((_, i) => "$" + (i + 1)).join(", ");
    const r = await this.q(keys.length ? `insert into announcements (${cols}) values (${ph}) returning id` : "insert into announcements default values returning id", keys.map((k) => row[k]));
    return String(r.rows[0].id);
  }
  async updateAnnouncement(id, row) {
    const keys = Object.keys(row).filter((k) => ["title", "body", "title_fr", "body_fr", "is_active"].includes(k));
    const sets = keys.map((k, i) => `${k} = $${i + 1}`).concat("updated_at = now()");
    await this.q(`update announcements set ${sets.join(", ")} where id = $${keys.length + 1}`, [...keys.map((k) => row[k]), id]);
  }
  async deleteAnnouncement(id) { await this.q("delete from announcements where id = $1", [id]); }
  async listActiveAnnouncements() {
    return (await this.q("select * from announcements where is_active = true order by created_at desc")).rows;
  }
  async listAnnouncementImages(ids) {
    if (!ids.length) return [];
    return (await this.q("select announcement_id, storage_url from announcement_images where announcement_id = any($1::uuid[]) order by created_at asc", [ids])).rows;
  }
  async addAnnouncementImage(announcementId, url) {
    await this.q("insert into announcement_images (announcement_id, storage_url) values ($1, $2)", [announcementId, url]);
  }
  async removeAnnouncementImage(url) { await this.q("delete from announcement_images where storage_url = $1", [url]); }

  // files
  async putFile(bucket, path, type, bytes, uploadedBy = null) {
    const r = await this.q("insert into files (bucket, path, content_type, bytes, uploaded_by) values ($1, $2, $3, $4, $5) on conflict do nothing", [bucket, path, type, bytes, uploadedBy]);
    return r.rowCount === 1;
  }
  async getFile(bucket, path) {
    const r = await this.q("select content_type, bytes, uploaded_by from files where bucket = $1 and path = $2", [bucket, path]);
    return r.rows[0] ? { type: r.rows[0].content_type, bytes: r.rows[0].bytes, uploaded_by: r.rows[0].uploaded_by } : null;
  }
  async totalFileBytes() { return Number((await this.q("select coalesce(sum(octet_length(bytes)), 0)::bigint as n from files")).rows[0].n); }
  async deleteFiles(bucket, paths) { await this.q("delete from files where bucket = $1 and path = any($2::text[])", [bucket, paths]); }

  // receipts + adjustments
  async insertReceipt(row) {
    const r = await this.q(
      "insert into receipts (driver_name, carrier_name, note, storage_path, public_url, email_sent) values ($1,$2,$3,$4,$5,false) returning id",
      [row.driver_name, row.carrier_name, row.note, row.storage_path, row.public_url],
    );
    return String(r.rows[0].id);
  }
  async getReceipt(id) { return (await this.q("select * from receipts where id = $1", [id])).rows[0] ?? null; }
  async insertAdjustment(row) {
    const r = await this.q(
      `insert into order_adjustments (id, order_num, order_kind, carrier_name, reporter_name, items, note, photo_url, transfer_locations, email_sent)
       values ($1,$2,$3,$4,$5,$6::jsonb,$7,$8,$9::jsonb,false) on conflict (id) do nothing`,
      [row.id, row.order_num, row.order_kind, row.carrier_name, row.reporter_name, JSON.stringify(row.items), row.note, row.photo_url ?? null,
        row.transfer_locations ? JSON.stringify(row.transfer_locations) : null],
    );
    return r.rowCount === 1;
  }
  async getAdjustment(id) { return (await this.q("select * from order_adjustments where id = $1", [id])).rows[0] ?? null; }
  async markEmailSent(table, id) {
    if (table !== "receipts" && table !== "order_adjustments") throw new Error("bad table");
    await this.q(`update ${table} set email_sent = true where id = $1`, [id]);
  }

  // order changes (overlay) + division contacts
  async getHistoryRow(num) { return (await this.q("select shipping_location_name, sale_location_name, carrier_name, customer from delivery_history where so_num = $1", [num])).rows[0] ?? null; }
  async insertOrderChanges(rows) {
    for (const r of rows) {
      await this.q(
        `insert into order_changes (id, change_id, order_num, order_kind, field, old_value, new_value, reason, changed_by, request_hash, context, notified_recipients, email_status)
         values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::jsonb,$12::jsonb,$13)`,
        [r.id, r.change_id, r.order_num, r.order_kind, r.field, r.old_value, r.new_value, r.reason, r.changed_by, r.request_hash, JSON.stringify(r.context ?? {}), JSON.stringify(r.notified_recipients ?? {}), r.email_status],
      );
    }
  }
  async listOrderChanges(num) { return (await this.q("select * from order_changes where order_num = $1 order by changed_at desc, field asc", [num])).rows; }
  async findRecentOrderChange(num, hash, sinceIso) { return (await this.q("select change_id, email_status from order_changes where order_num = $1 and request_hash = $2 and changed_at >= $3 limit 1", [num, hash, sinceIso])).rows[0] ?? null; }
  async setOrderChangeEmailStatus(changeId, status) { await this.q("update order_changes set email_status = $2 where change_id = $1", [changeId, status]); }
  async getOrderChange(changeId) { return (await this.q("select * from order_changes where change_id = $1 order by field asc", [changeId])).rows; }
  async changedSummary(nums) {
    const rows = (await this.q("select order_num, count(distinct change_id)::int as count, max(changed_at) as last_at, (array_agg(changed_by order by changed_at desc))[1] as last_by from order_changes where order_num = any($1::text[]) group by order_num", [nums])).rows;
    return Object.fromEntries(rows.map((r) => [r.order_num, { count: r.count, lastAt: r.last_at, lastBy: r.last_by }]));
  }
  async listDivisionContacts() { return (await this.q("select division, emails, location_keywords, updated_by, updated_at from division_contacts order by division")).rows; }
  async upsertDivisionContact(r) {
    await this.q("insert into division_contacts (division, emails, location_keywords, updated_by) values ($1,$2::text[],$3::text[],$4) on conflict (division) do update set emails = excluded.emails, location_keywords = excluded.location_keywords, updated_by = excluded.updated_by, updated_at = now()", [r.division, r.emails, r.location_keywords, r.updated_by]);
  }

  // delivery history (one multi-row upsert; rows are already de-duplicated by so_num)
  /** ownerNames: null = any row (SuperUser); otherwise an existing row is replaced only when it already carries one of these names. */
  async upsertHistory(rows, ownerNames = null) {
    if (!rows.length) return 0;
    const cols = HISTORY_COLUMNS;
    const params = [];
    const tuples = rows.map((r) => {
      const ph = cols.map((c) => { params.push(r[c] ?? null); return "$" + params.length; });
      return "(" + ph.join(",") + ")";
    });
    const updates = cols.filter((c) => c !== "so_num").map((c) => `${c} = excluded.${c}`).concat("updated_at = now()");
    let sql = `insert into delivery_history (${cols.join(",")}) values ${tuples.join(",")} on conflict (so_num) do update set ${updates.join(", ")}`;
    if (ownerNames) { params.push(ownerNames); sql += ` where delivery_history.carrier_name = any($${params.length}::text[])`; }
    return (await this.q(sql, params)).rowCount;
  }
  async listHistory({ from, to, carrierNames, carrierIds }) {
    const params = [from, to];
    let sql = "select * from delivery_history where ship_date >= $1 and ship_date < $2";
    if (carrierNames) { params.push(carrierNames); sql += ` and carrier_name = any($${params.length}::text[])`; }
    if (carrierIds) { params.push(carrierIds); sql += ` and carrier_id = any($${params.length}::bigint[])`; }
    sql += " order by ship_date desc limit 2000";
    return (await this.q(sql, params)).rows;
  }

  // email bookkeeping
  async countRecentSends(carrier, sinceIso) {
    const r = await this.q("select count(*)::int as n from email_send_log where metadata->>'carrier' = $1 and status in ('pending','sent') and created_at >= $2", [carrier, sinceIso]);
    return r.rows[0].n;
  }
  /**
   * Atomic claim of one send: per-carrier advisory lock, hourly count, then insert-first against the unique
   * index on the idempotency key (pending/sent rows). -> { state: 'claimed', id } | { state: 'duplicate' } | { state: 'throttled' }
   */
  async claimSend(rec, { key, carrier, limit, sinceIso, staleBeforeIso }) {
    const c = await this.pool.connect();
    try {
      await c.query("begin");
      await c.query("select pg_advisory_xact_lock(hashtext($1))", [carrier]);
      // crash between claim and send: an old 'pending' row expires so it neither blocks retries nor counts toward the cap
      if (staleBeforeIso) await c.query("update email_send_log set status = 'failed', error_message = 'stale_pending' where status = 'pending' and created_at < $1", [staleBeforeIso]);
      const n = (await c.query("select count(*)::int as n from email_send_log where metadata->>'carrier' = $1 and status in ('pending','sent') and created_at >= $2", [carrier, sinceIso])).rows[0].n;
      if (n >= limit) { await c.query("rollback"); return { state: "throttled" }; }
      const r = await c.query("insert into email_send_log (message_id, template_name, recipient_email, status, error_message, metadata) values ($1,$2,$3,$4,$5,$6::jsonb) on conflict ((metadata->>'idempotency_key')) where status in ('pending','sent') do nothing returning id",
        [rec.message_id, rec.template_name, rec.recipient_email, rec.status, rec.error_message ?? null, JSON.stringify({ ...(rec.metadata ?? {}), idempotency_key: key, carrier })]);
      if (!r.rowCount) { await c.query("rollback"); return { state: "duplicate" }; }
      await c.query("commit");
      return { state: "claimed", id: String(r.rows[0].id) };
    } catch (e) {
      try { await c.query("rollback"); } catch { /* connection already gone */ }
      throw e;
    } finally {
      c.release();
    }
  }
  async hasSendWithKey(key) {
    const r = await this.q("select 1 from email_send_log where metadata->>'idempotency_key' = $1 and status in ('pending','sent') limit 1", [key]);
    return r.rowCount > 0;
  }
  async isSuppressed(email) { return (await this.q("select 1 from suppressed_emails where email = $1", [email])).rowCount > 0; }
  async logSend(rec) {
    const r = await this.q(
      "insert into email_send_log (message_id, template_name, recipient_email, status, error_message, metadata) values ($1,$2,$3,$4,$5,$6::jsonb) returning id",
      [rec.message_id, rec.template_name, rec.recipient_email, rec.status, rec.error_message ?? null, JSON.stringify(rec.metadata ?? {})],
    );
    return String(r.rows[0].id);
  }
  async updateSend(id, patch) {
    await this.q("update email_send_log set status = coalesce($2, status), error_message = coalesce($3, error_message) where id = $1", [id, patch.status ?? null, patch.error_message ?? null]);
  }
  async unsubscribeTokenFor(email) {
    const cand = (await import("node:crypto")).randomBytes(32).toString("hex");
    await this.q("insert into email_unsubscribe_tokens (email, token) values ($1, $2) on conflict (email) do nothing", [email, cand]);
    const r = await this.q("select token, used_at from email_unsubscribe_tokens where email = $1", [email]);
    return r.rows[0].used_at ? "used" : r.rows[0].token;
  }
  async getUnsubscribeToken(token) {
    return (await this.q("select email, used_at from email_unsubscribe_tokens where token = $1", [token])).rows[0] ?? null;
  }
  async useUnsubscribeToken(token) {
    const r = await this.q("update email_unsubscribe_tokens set used_at = now() where token = $1 and used_at is null returning email", [token]);
    if (!r.rowCount) return null;
    const email = r.rows[0].email;
    await this.q("insert into suppressed_emails (email, reason) values ($1, 'unsubscribe') on conflict (email) do nothing", [email.toLowerCase()]);
    return email;
  }
}
