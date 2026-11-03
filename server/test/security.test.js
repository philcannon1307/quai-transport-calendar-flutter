import test from "node:test";
import assert from "node:assert/strict";
import { startApp, startStub, STUB_ACCOUNTS, ORIGIN } from "./helpers.js";

test("CORS: preflight from the allowed origin works; others are refused", async () => {
  const app = await startApp({});
  try {
    const ok = await app.call(null, { method: "OPTIONS" });
    assert.equal(ok.status, 204);
    assert.equal(ok.headers.get("access-control-allow-origin"), ORIGIN);
    assert.match(ok.headers.get("access-control-allow-methods"), /POST/);
    assert.match(ok.headers.get("access-control-allow-headers"), /Content-Type/i);
    assert.equal(ok.headers.get("vary"), "Origin");

    const evil = await app.call(null, { method: "OPTIONS", origin: "https://evil.example.com" });
    assert.equal(evil.status, 403);
    assert.equal(evil.headers.get("access-control-allow-origin"), null);

    const post = await app.call({ carrier: "InterQL", code: "x" }, { origin: "https://evil.example.com" });
    assert.equal(post.status, 403, "a browser from another site cannot even reach the exchange logic");
    assert.equal(post.headers.get("access-control-allow-origin"), null);

    const sub = await app.call({ carrier: "InterQL", code: "x" }, { origin: "https://app.example.com.evil.com" });
    assert.equal(sub.status, 403, "no prefix/suffix matching");
  } finally { await app.close(); }
});

test("rate limit: 5 bad codes for one carrier from one IP -> 429 + Retry-After, even for the right code", async () => {
  const stub = await startStub(STUB_ACCOUNTS);
  const app = await startApp({ stub });
  try {
    const ip = "203.0.113.7";
    for (let i = 0; i < 5; i++) assert.equal((await app.call({ carrier: "Gat - Sam", code: "00000" + i }, { ip })).status, 401);
    const locked = await app.call({ carrier: "Gat - Sam", code: "999999" }, { ip });
    assert.equal(locked.status, 429);
    assert.ok(Number(locked.headers.get("retry-after")) > 0);
    assert.equal(stub.calls.length, 0, "a locked login never reaches the job service");
    // another IP is not locked by this one...
    assert.equal((await app.call({ carrier: "Gat - Sam", code: "999999" }, { ip: "203.0.113.8" })).status, 200);
    // ...and the same IP can still use a different carrier
    assert.equal((await app.call({ carrier: "SADM - Steve", code: "888888" }, { ip })).status, 200);
  } finally { await app.close(); await stub.close(); }
});

test("rate limit: a distributed guess against one carrier (many IPs) hits the global lock", async () => {
  const stub = await startStub(STUB_ACCOUNTS);
  const app = await startApp({ stub });
  try {
    for (let i = 0; i < 20; i++) await app.call({ carrier: "Gat - Sam", code: String(100000 + i) }); // fresh IP each
    const r = await app.call({ carrier: "Gat - Sam", code: "999999" });
    assert.equal(r.status, 429);
    assert.ok(Number(r.headers.get("retry-after")) > 0);
  } finally { await app.close(); await stub.close(); }
});

test("rate limit: unknown carrier names share one bucket (no unbounded keys, still throttled)", async () => {
  const app = await startApp({});
  try {
    const ip = "203.0.113.50";
    for (let i = 0; i < 5; i++) await app.call({ carrier: "ghost" + i, code: "1" }, { ip });
    assert.equal((await app.call({ carrier: "ghost99", code: "1" }, { ip })).status, 429);
  } finally { await app.close(); }
});

test("rate limit: SuperUser locks after 3 failures for 30 min, even with the right password", async () => {
  const stub = await startStub(STUB_ACCOUNTS);
  const app = await startApp({ stub });
  try {
    const ip = "203.0.113.9";
    for (let i = 0; i < 3; i++) assert.equal((await app.call({ carrier: "SuperUser", username: "boss", code: "bad" + i }, { ip })).status, 401);
    const r = await app.call({ carrier: "SuperUser", username: "boss", code: "super-secret-pw" }, { ip });
    assert.equal(r.status, 429);
    assert.ok(Number(r.headers.get("retry-after")) >= 1700);
  } finally { await app.close(); await stub.close(); }
});

test("rate limit: SuperUser global lock after 10 failures across IPs", async () => {
  const app = await startApp({});
  try {
    for (let i = 0; i < 10; i++) await app.call({ carrier: "SuperUser", username: "boss", code: "bad" + i });
    assert.equal((await app.call({ carrier: "SuperUser", username: "boss", code: "super-secret-pw" })).status, 429);
  } finally { await app.close(); }
});

test("rate limit: a lock expires with time", async () => {
  let t = 1_000_000;
  const stub = await startStub(STUB_ACCOUNTS);
  const app = await startApp({ stub, now: () => t });
  try {
    const ip = "203.0.113.10";
    for (let i = 0; i < 5; i++) await app.call({ carrier: "Gat - Sam", code: "00000" + i }, { ip });
    assert.equal((await app.call({ carrier: "Gat - Sam", code: "999999" }, { ip })).status, 429);
    t += 16 * 60_000;
    assert.equal((await app.call({ carrier: "Gat - Sam", code: "999999" }, { ip })).status, 200);
  } finally { await app.close(); await stub.close(); }
});

test("rate limit: more than 30 requests/min from one IP -> 429", async () => {
  const app = await startApp({});
  try {
    const ip = "203.0.113.11";
    let last;
    for (let i = 0; i < 31; i++) last = await app.call({ carrier: "ghost", code: "1" }, { ip: ip });
    assert.equal(last.status, 429);
  } finally { await app.close(); }
});

test("client IP comes from the proxy-appended X-Forwarded-For entry, not a spoofed first one", async () => {
  const stub = await startStub(STUB_ACCOUNTS);
  const app = await startApp({ stub });
  try {
    // The attacker rotates the leftmost value; our proxy appends the real IP on the right.
    for (let i = 0; i < 5; i++) {
      await app.call({ carrier: "Gat - Sam", code: "00000" + i }, { headers: { "X-Forwarded-For": "1.2.3." + i + ", 198.51.100.99" } });
    }
    const r = await app.call({ carrier: "Gat - Sam", code: "999999" }, { headers: { "X-Forwarded-For": "9.9.9.9, 198.51.100.99" } });
    assert.equal(r.status, 429);
  } finally { await app.close(); await stub.close(); }
});
