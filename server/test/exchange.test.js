import test from "node:test";
import assert from "node:assert/strict";
import { startApp, startStub, STUB_ACCOUNTS, ORIGIN, SECRET } from "./helpers.js";
import { verifySession } from "../src/jwt.js";

// Request/response shapes are the ones lib/api/auth_service.dart sends and reads.

test("carrier login: Dart request shape -> Dart response shape, scoped to the truck", async () => {
  const stub = await startStub(STUB_ACCOUNTS);
  const app = await startApp({ stub });
  try {
    const r = await app.call({ carrier: "Gat - Sam", code: "999999" });
    assert.equal(r.status, 200);
    assert.equal(r.json.accessToken, "job-token:Gat - Sam");
    assert.deepEqual(r.json.linkedTokens, {});
    assert.equal(r.json.role, "carrier");
    const p = verifySession(r.json.sessionToken, SECRET);
    assert.equal(p.sub, "Gat - Sam");
    assert.equal(p.app_role, "carrier");
    assert.deepEqual(p.trucks, ["64"]);
    assert.equal(p.exp, r.json.exp);
    assert.deepEqual(stub.calls.map((c) => c.username), ["Gat - Sam"], "only its own truck is logged in");
    assert.equal(r.headers.get("access-control-allow-origin"), ORIGIN);
    assert.equal(r.headers.get("cache-control"), "no-store");
  } finally { await app.close(); await stub.close(); }
});

test("InterQL: primary RIDEAU (truck 3) + linked OPEN GOOSENECK (truck 4), nothing else", async () => {
  const stub = await startStub(STUB_ACCOUNTS);
  const app = await startApp({ stub });
  try {
    const r = await app.call({ carrier: "InterQL", code: "111111" });
    assert.equal(r.status, 200);
    assert.equal(r.json.accessToken, "job-token:RIDEAU GOOSENECK");
    assert.deepEqual(r.json.linkedTokens, { "OPEN GOOSENECK": "job-token:OPEN GOOSENECK" });
    assert.equal(r.json.role, "carrier");
    assert.deepEqual(verifySession(r.json.sessionToken, SECRET).trucks, ["3", "4"]);
    assert.deepEqual(verifySession(r.json.sessionToken, SECRET).names.sort(), ["InterQL", "OPEN GOOSENECK", "RIDEAU GOOSENECK"]);
    assert.deepEqual(stub.calls.map((c) => c.username).sort(), ["OPEN GOOSENECK", "RIDEAU GOOSENECK"]);
  } finally { await app.close(); await stub.close(); }
});

test("SADM - Logistique: role logistique, backend account SADM - David + Gooseneck tokens", async () => {
  const stub = await startStub(STUB_ACCOUNTS);
  const app = await startApp({ stub });
  try {
    const r = await app.call({ carrier: "SADM - Logistique", code: "333333" });
    assert.equal(r.status, 200);
    assert.equal(r.json.role, "logistique");
    assert.equal(r.json.accessToken, "job-token:SADM - David");
    assert.deepEqual(Object.keys(r.json.linkedTokens).sort(), ["OPEN GOOSENECK", "RIDEAU GOOSENECK"]);
    assert.equal(verifySession(r.json.sessionToken, SECRET).app_role, "logistique");
  } finally { await app.close(); await stub.close(); }
});

test("a carrier's code does not log in as another carrier", async () => {
  const stub = await startStub(STUB_ACCOUNTS);
  const app = await startApp({ stub });
  try {
    const r = await app.call({ carrier: "InterQL", code: "999999" });
    assert.equal(r.status, 401);
    assert.equal(stub.calls.length, 0, "no job-service login on a bad code");
  } finally { await app.close(); await stub.close(); }
});

test("wrong code and unknown carrier give the SAME generic 401", async () => {
  const stub = await startStub(STUB_ACCOUNTS);
  const app = await startApp({ stub });
  try {
    const a = await app.call({ carrier: "InterQL", code: "000000" });
    const b = await app.call({ carrier: "Nobody", code: "000000" });
    const c = await app.call({ carrier: "Lindsay - Cole", code: "000000" }); // roster member with no configured credentials
    for (const x of [a, b, c]) assert.equal(x.status, 401);
    assert.equal(a.text, b.text);
    assert.equal(a.text, c.text);
    assert.deepEqual(a.json, { error: "invalid_credentials" });
  } finally { await app.close(); await stub.close(); }
});

test("SuperUser: Dart request shape; every backend account gets a token; role from the server", async () => {
  const stub = await startStub(STUB_ACCOUNTS);
  const app = await startApp({ stub });
  try {
    const r = await app.call({ carrier: "SuperUser", username: "boss", code: "super-secret-pw" });
    assert.equal(r.status, 200);
    assert.equal(r.json.role, "superuser");
    assert.ok(r.json.accessToken);
    assert.deepEqual(Object.keys(r.json.linkedTokens).sort(), Object.keys(STUB_ACCOUNTS).sort());
    // accounts for which this test environment configured no credentials are reported, never silently dropped
    assert.ok(Array.isArray(r.json.unavailable) && r.json.unavailable.includes("DA TRANSPORT"));
    assert.ok(!r.json.unavailable.includes("OPEN GOOSENECK"));
    const p = verifySession(r.json.sessionToken, SECRET);
    assert.equal(p.app_role, "superuser");
    assert.ok(p.trucks.includes("3") && p.trucks.includes("62"));
  } finally { await app.close(); await stub.close(); }
});

test("SuperUser: wrong username, wrong password, and a carrier code are all refused", async () => {
  const stub = await startStub(STUB_ACCOUNTS);
  const app = await startApp({ stub });
  try {
    for (const body of [
      { carrier: "SuperUser", username: "boss", code: "nope" },
      { carrier: "SuperUser", username: "root", code: "super-secret-pw" },
      { carrier: "SuperUser", code: "super-secret-pw" },
      { carrier: "SuperUser", username: "SuperUser", code: "111111" },
    ]) assert.equal((await app.call(body)).status, 401, JSON.stringify(body));
    assert.equal(stub.calls.length, 0);
  } finally { await app.close(); await stub.close(); }
});

test("SuperUser is refused when it is not configured", async () => {
  const app = await startApp({ env: { SUPERUSER_USERNAME: "", SUPERUSER_PASSWORD_HASH: "" } });
  try {
    assert.equal((await app.call({ carrier: "SuperUser", username: "boss", code: "x" })).status, 401);
  } finally { await app.close(); }
});

test("SuperUser plain-password mode works too", async () => {
  const stub = await startStub(STUB_ACCOUNTS);
  const app = await startApp({ stub, env: { SUPERUSER_PASSWORD_HASH: "", SUPERUSER_PASSWORD: "plain-pw" } });
  try {
    assert.equal((await app.call({ carrier: "SuperUser", username: "boss", code: "plain-pw" })).status, 200);
    assert.equal((await app.call({ carrier: "SuperUser", username: "boss", code: "super-secret-pw" })).status, 401);
  } finally { await app.close(); await stub.close(); }
});

test("SuperUser: partial upstream failure still signs in and reports what is unavailable", async () => {
  const stub = await startStub(STUB_ACCOUNTS, { failFor: new Set(["Gat - Sam"]) });
  const app = await startApp({ stub });
  try {
    const r = await app.call({ carrier: "SuperUser", username: "boss", code: "super-secret-pw" });
    assert.equal(r.status, 200);
    assert.ok(r.json.unavailable.includes("Gat - Sam"));
    assert.ok(!("Gat - Sam" in r.json.linkedTokens));
  } finally { await app.close(); await stub.close(); }
});

test("job service down -> 502 (not a credentials error); wrong server-side password -> 502", async () => {
  const down = await startApp({});
  try {
    const r = await down.call({ carrier: "Gat - Sam", code: "999999" });
    assert.equal(r.status, 502);
    assert.deepEqual(r.json, { error: "upstream_unavailable" });
  } finally { await down.close(); }
  const stub = await startStub({ ...STUB_ACCOUNTS, "Gat - Sam": "changed-upstream" });
  const app = await startApp({ stub });
  try {
    assert.equal((await app.call({ carrier: "Gat - Sam", code: "999999" })).status, 502);
  } finally { await app.close(); await stub.close(); }
});

test("a job-service 5xx on any linked account fails the whole login (no half-scoped session)", async () => {
  const stub = await startStub(STUB_ACCOUNTS, { failFor: new Set(["OPEN GOOSENECK"]) });
  const app = await startApp({ stub });
  try {
    assert.equal((await app.call({ carrier: "InterQL", code: "111111" })).status, 502);
  } finally { await app.close(); await stub.close(); }
});

test("secrets never appear in responses or logs", async () => {
  const stub = await startStub(STUB_ACCOUNTS);
  const app = await startApp({ stub });
  try {
    const ok = await app.call({ carrier: "InterQL", code: "111111" });
    const bad = await app.call({ carrier: "InterQL", code: "654321" });
    const su = await app.call({ carrier: "SuperUser", username: "boss", code: "super-secret-pw" });
    const suBad = await app.call({ carrier: "SuperUser", username: "boss", code: "wrong-pw-777" });
    const logs = JSON.stringify(app.logs);
    for (const secret of ["111111", "654321", "rideau-pw", "open-pw", "david-pw", "super-secret-pw", "wrong-pw-777", SECRET, ok.json.sessionToken, ok.json.accessToken]) {
      assert.ok(!logs.includes(secret), "log leaked a secret");
    }
    for (const r of [ok, bad, su, suBad]) {
      for (const secret of ["rideau-pw", "open-pw", "david-pw", "super-secret-pw", SECRET]) assert.ok(!r.text.includes(secret));
    }
    assert.ok(app.logs.some((l) => l.e === "login_ok"));
  } finally { await app.close(); await stub.close(); }
});

test("malformed input: 400 for bad bodies, 415 for wrong content type, 413 for oversized", async () => {
  const app = await startApp({});
  try {
    assert.equal((await app.call(null, { raw: "{not json" })).status, 400);
    assert.equal((await app.call({ carrier: 5, code: "x" })).status, 400);
    assert.equal((await app.call({ carrier: "InterQL" })).status, 400);
    assert.equal((await app.call({ carrier: "InterQL", code: "x".repeat(201) })).status, 400);
    assert.equal((await app.call([1, 2])).status, 400);
    assert.equal((await app.call(null, { raw: "x", headers: { "Content-Type": "text/plain" } })).status, 415);
    assert.equal((await app.call(null, { raw: JSON.stringify({ carrier: "x".repeat(6000), code: "1" }) })).status, 413);
  } finally { await app.close(); }
});

test("other routes: /health is open, unknown paths 404, GET /exchange 405", async () => {
  const app = await startApp({});
  try {
    const h = await app.call(null, { method: "GET", path: "/health", origin: null });
    assert.equal(h.status, 200);
    assert.deepEqual(h.json, { status: "ok" });
    assert.equal((await app.call(null, { method: "GET", path: "/nope", origin: null })).status, 404);
    assert.equal((await app.call(null, { method: "GET", path: "/exchange" })).status, 405);
  } finally { await app.close(); }
});
