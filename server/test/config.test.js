import test from "node:test";
import assert from "node:assert/strict";
import { loadConfig, hashPassword } from "../src/config.js";
import { makeEnv, SECRET } from "./helpers.js";

const errs = (over) => loadConfig(makeEnv(over)).errors;

test("a complete environment is valid", () => {
  const r = loadConfig(makeEnv());
  assert.deepEqual(r.errors, []);
  assert.equal(r.config.superUser.username, "boss");
  assert.equal(r.config.sessionTtlSeconds, 43200);
});

test("required variables are enforced", () => {
  assert.ok(errs({ CARRIER_CREDENTIALS_JSON: "" }).some((e) => /CARRIER_CREDENTIALS_JSON/.test(e)));
  assert.ok(errs({ CARRIER_CREDENTIALS_JSON: "{oops" }).some((e) => /valid JSON/.test(e)));
  assert.ok(errs({ SESSION_JWT_SECRET: "short" }).some((e) => /SESSION_JWT_SECRET/.test(e)));
  assert.ok(errs({ ALLOWED_ORIGINS: "" }).some((e) => /ALLOWED_ORIGINS/.test(e)));
});

test("CORS origins must be exact; wildcard and plain http are refused", () => {
  assert.ok(errs({ ALLOWED_ORIGINS: "*" }).some((e) => /not accepted/.test(e)));
  assert.ok(errs({ ALLOWED_ORIGINS: "http://evil.example.com" }).some((e) => /https/.test(e)));
  assert.ok(errs({ ALLOWED_ORIGINS: "https://a.example.com/path" }).length > 0);
  assert.deepEqual(errs({ ALLOWED_ORIGINS: "https://a.example.com/, http://localhost:5000" }), []);
});

test("SuperUser is optional (disabled with a warning) and a bad hash is refused", () => {
  const r = loadConfig(makeEnv({ SUPERUSER_USERNAME: "", SUPERUSER_PASSWORD_HASH: "" }));
  assert.equal(r.config.superUser, null);
  assert.ok(r.warnings.some((w) => /SuperUser/.test(w)));
  assert.ok(errs({ SUPERUSER_PASSWORD_HASH: "plaintext" }).some((e) => /HASH/.test(e)));
});

test("error and warning messages never contain secret values", () => {
  const env = makeEnv({ SESSION_JWT_SECRET: "tiny", CARRIER_CREDENTIALS_JSON: JSON.stringify({ InterQL: "supersecretvalue" }) });
  const r = loadConfig(env);
  const all = JSON.stringify([r.errors, r.warnings]);
  assert.ok(!all.includes("supersecretvalue"));
  assert.ok(!all.includes("tiny"));
  assert.ok(!all.includes(SECRET));
});

test("hashPassword is salted", () => {
  assert.notEqual(hashPassword("a"), hashPassword("a"));
  assert.match(hashPassword("a"), /^scrypt\$/);
});

test("credential keys match the roster ignoring accents, case and spaces", async () => {
  const { normName, carrierByName } = await import("../src/roster.js");
  assert.equal(normName("  SADM -  Éric "), "sadm - eric");
  assert.equal(carrierByName("SADM - Eric")?.displayName, "SADM - Éric");
  assert.equal(carrierByName("sadm - éric")?.displayName, "SADM - Éric");
  const creds = JSON.parse(makeEnv().CARRIER_CREDENTIALS_JSON);
  delete creds["SADM - Éric"];
  creds["SADM - Eric"] = "444444";
  const { config, warnings } = loadConfig(makeEnv({ CARRIER_CREDENTIALS_JSON: JSON.stringify(creds) }));
  assert.equal(config.credentials.get("SADM - Éric")?.code, "444444");
  assert.ok(!warnings.join(" ").includes("SADM - Éric"));
});
