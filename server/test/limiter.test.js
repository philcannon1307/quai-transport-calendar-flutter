import test from "node:test";
import assert from "node:assert/strict";
import { FailureLimiter, RateLimiter } from "../src/limiter.js";

test("FailureLimiter locks after max failures and unlocks after lockMs", () => {
  let t = 0;
  const l = new FailureLimiter({ max: 3, windowMs: 1000, lockMs: 5000, now: () => t });
  l.fail("k"); l.fail("k");
  assert.equal(l.retryAfter("k"), 0);
  l.fail("k");
  assert.equal(l.retryAfter("k"), 5);
  t = 4999;
  assert.equal(l.retryAfter("k"), 1);
  t = 5001;
  assert.equal(l.retryAfter("k"), 0);
});

test("failures outside the window do not add up; reset clears", () => {
  let t = 0;
  const l = new FailureLimiter({ max: 2, windowMs: 1000, lockMs: 5000, now: () => t });
  l.fail("k"); t = 2000; l.fail("k");
  assert.equal(l.retryAfter("k"), 0);
  l.reset("k"); t = 2100; l.fail("k");
  assert.equal(l.retryAfter("k"), 0);
});

test("FailureLimiter is bounded in memory", () => {
  const l = new FailureLimiter({ max: 5, windowMs: 1000, lockMs: 1000, maxKeys: 10 });
  for (let i = 0; i < 100; i++) l.fail("k" + i);
  assert.ok(l.map.size <= 10);
});

test("RateLimiter allows max per window then blocks, then recovers", () => {
  let t = 0;
  const r = new RateLimiter({ max: 2, windowMs: 1000, now: () => t });
  assert.equal(r.hit("a"), 0); assert.equal(r.hit("a"), 0);
  assert.ok(r.hit("a") > 0);
  assert.equal(r.hit("b"), 0);
  t = 1001;
  assert.equal(r.hit("a"), 0);
});
