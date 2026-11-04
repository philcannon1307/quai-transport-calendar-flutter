// Per-login upload quota (count + bytes per window). In memory, like the other limiters: one replica.
export class UploadQuota {
  constructor({ maxCount, maxBytes, windowMs = 3600_000, now = Date.now, maxKeys = 5000 }) {
    Object.assign(this, { maxCount, maxBytes, windowMs, now, maxKeys });
    this.map = new Map();
  }
  live(key) {
    const e = this.map.get(key);
    if (e && this.now() - e.start >= this.windowMs) { this.map.delete(key); return null; }
    return e ?? null;
  }
  /** -> 0 when allowed, otherwise seconds until the window resets. */
  check(key) {
    const e = this.live(key);
    if (!e || (e.count < this.maxCount && e.bytes < this.maxBytes)) return 0;
    return Math.max(1, Math.ceil((e.start + this.windowMs - this.now()) / 1000));
  }
  add(key, bytes) {
    const e = this.live(key) ?? { start: this.now(), count: 0, bytes: 0 };
    e.count += 1;
    e.bytes += bytes;
    this.map.delete(key);
    this.map.set(key, e);
    while (this.map.size > this.maxKeys) this.map.delete(this.map.keys().next().value);
  }
}
