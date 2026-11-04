// In-memory store with the same interface as PgStore. Used by the tests and for local runs without a
// database (DATA_STORE=memory). Everything is lost on restart.
import { randomUUID, randomBytes } from "node:crypto";

export class MemoryStore {
  constructor() {
    this.announcements = [];
    this.images = [];
    this.files = new Map(); // "bucket/path" -> { type, bytes, createdAt }
    this.receipts = [];
    this.adjustments = [];
    this.history = new Map(); // so_num -> row
    this.sendLog = [];
    this.suppressed = new Map(); // email -> { reason }
    this.tokens = new Map(); // email -> { token, used_at }
  }

  async ping() { return true; }

  // announcements
  async insertAnnouncement(row) {
    const rec = { id: randomUUID(), is_active: true, created_at: new Date().toISOString(), updated_at: new Date().toISOString(), title: "", body: "", title_fr: null, body_fr: null, ...row };
    this.announcements.push(rec);
    return rec.id;
  }
  async updateAnnouncement(id, row) {
    const a = this.announcements.find((x) => x.id === id);
    if (a) Object.assign(a, row, { updated_at: new Date().toISOString() });
  }
  async deleteAnnouncement(id) {
    this.announcements = this.announcements.filter((x) => x.id !== id);
    this.images = this.images.filter((i) => i.announcement_id !== id);
  }
  async listActiveAnnouncements() {
    return this.announcements.filter((a) => a.is_active).sort((a, b) => (a.created_at < b.created_at ? 1 : -1));
  }
  async listAnnouncementImages(ids) {
    return this.images.filter((i) => ids.includes(i.announcement_id)).sort((a, b) => (a.created_at < b.created_at ? -1 : 1));
  }
  async addAnnouncementImage(announcementId, url) {
    this.images.push({ id: randomUUID(), announcement_id: announcementId, storage_url: url, created_at: new Date().toISOString() });
  }
  async removeAnnouncementImage(url) { this.images = this.images.filter((i) => i.storage_url !== url); }

  // files
  async putFile(bucket, path, type, bytes) {
    const k = bucket + "/" + path;
    if (this.files.has(k)) return false;
    this.files.set(k, { type, bytes: Buffer.from(bytes), createdAt: new Date().toISOString() });
    return true;
  }
  async getFile(bucket, path) { return this.files.get(bucket + "/" + path) ?? null; }
  async deleteFiles(bucket, paths) { for (const p of paths) this.files.delete(bucket + "/" + p); }

  // receipts + adjustments
  async insertReceipt(row) {
    const rec = { id: randomUUID(), created_at: new Date().toISOString(), email_sent: false, ...row };
    this.receipts.push(rec);
    return rec.id;
  }
  async getReceipt(id) { return this.receipts.find((r) => r.id === id) ?? null; }
  async insertAdjustment(row) {
    if (this.adjustments.some((a) => a.id === row.id)) return false;
    this.adjustments.push({ created_at: new Date().toISOString(), email_sent: false, ...row });
    return true;
  }
  async getAdjustment(id) { return this.adjustments.find((a) => a.id === id) ?? null; }
  async markEmailSent(table, id) {
    const rows = table === "receipts" ? this.receipts : this.adjustments;
    const r = rows.find((x) => x.id === id);
    if (r) r.email_sent = true;
  }

  // delivery history
  async upsertHistory(rows) {
    for (const r of rows) this.history.set(r.so_num, { ...(this.history.get(r.so_num) ?? {}), ...r, updated_at: new Date().toISOString() });
  }
  async listHistory({ from, to, carrierNames, carrierIds }) {
    return [...this.history.values()]
      .filter((r) => r.ship_date != null && r.ship_date >= from && r.ship_date < to)
      .filter((r) => !carrierNames || carrierNames.includes(r.carrier_name))
      .filter((r) => !carrierIds || carrierIds.includes(r.carrier_id))
      .sort((a, b) => (a.ship_date < b.ship_date ? 1 : -1))
      .slice(0, 2000);
  }

  // email bookkeeping
  async countRecentSends(carrier, sinceIso) {
    return this.sendLog.filter((l) => l.metadata.carrier === carrier && ["pending", "sent"].includes(l.status) && l.created_at >= sinceIso).length;
  }
  async hasSendWithKey(key) { return this.sendLog.some((l) => l.metadata.idempotency_key === key && ["pending", "sent"].includes(l.status)); }
  async isSuppressed(email) { return this.suppressed.has(email); }
  async logSend(rec) { const r = { id: randomUUID(), created_at: new Date().toISOString(), ...rec }; this.sendLog.push(r); return r.id; }
  async updateSend(id, patch) { Object.assign(this.sendLog.find((l) => l.id === id) ?? {}, patch); }
  async unsubscribeTokenFor(email) {
    const e = this.tokens.get(email);
    if (e) return e.used_at ? "used" : e.token;
    const token = randomBytes(32).toString("hex");
    this.tokens.set(email, { token, used_at: null });
    return token;
  }
  async getUnsubscribeToken(token) {
    for (const [email, v] of this.tokens) if (v.token === token) return { email, used_at: v.used_at };
    return null;
  }
  /** Atomic: true only for the call that flipped used_at. */
  async useUnsubscribeToken(token) {
    for (const [email, v] of this.tokens) {
      if (v.token === token) {
        if (v.used_at) return null;
        v.used_at = new Date().toISOString();
        this.suppressed.set(email.toLowerCase(), { reason: "unsubscribe" });
        return email;
      }
    }
    return null;
  }
}
