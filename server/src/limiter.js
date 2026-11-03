// In-memory limiters. One Railway replica is assumed (see README); with several
// replicas each keeps its own counters, so run exactly one.

/** Counts failures; after `max` within `windowMs` the key is locked for `lockMs`. */
export class FailureLimiter {
  constructor({ max, windowMs, lockMs, now = Date.now, maxKeys = 20000 }) {
    Object.assign(this, { max, windowMs, lockMs, now, maxKeys });
    this.map = new Map();
  }
  /** -> 0 when allowed, otherwise seconds to wait. */
  retryAfter(key) {
    const e = this.map.get(key);
    if (!e || !e.lockedUntil) return 0;
    const left = e.lockedUntil - this.now();
    if (left <= 0) {
      this.map.delete(key);
      return 0;
    }
    return Math.ceil(left / 1000);
  }
  fail(key) {
    const t = this.now();
    const e = this.map.get(key) ?? { fails: [], lockedUntil: 0 };
    e.fails = e.fails.filter((x) => t - x < this.windowMs);
    e.fails.push(t);
    if (e.fails.length >= this.max) {
      e.lockedUntil = t + this.lockMs;
      e.fails = [];
    }
    this.map.delete(key);
    this.map.set(key, e);
    while (this.map.size > this.maxKeys) this.map.delete(this.map.keys().next().value);
  }
  reset(key) {
    this.map.delete(key);
  }
}

/** Fixed-window request counter. */
export class RateLimiter {
  constructor({ max, windowMs, now = Date.now, maxKeys = 20000 }) {
    Object.assign(this, { max, windowMs, now, maxKeys });
    this.map = new Map();
  }
  /** -> 0 when allowed (and counted), otherwise seconds to wait. */
  hit(key) {
    const t = this.now();
    let e = this.map.get(key);
    if (!e || t - e.start >= this.windowMs) e = { start: t, count: 0 };
    e.count += 1;
    this.map.delete(key);
    this.map.set(key, e);
    while (this.map.size > this.maxKeys) this.map.delete(this.map.keys().next().value);
    if (e.count > this.max) return Math.max(1, Math.ceil((e.start + this.windowMs - t) / 1000));
    return 0;
  }
}
