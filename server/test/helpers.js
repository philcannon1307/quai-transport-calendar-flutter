import http from "node:http";
import { createApp } from "../src/app.js";
import { loadConfig, hashPassword } from "../src/config.js";

export const ORIGIN = "https://app.example.com";
export const SECRET = "test-secret-test-secret-test-secret-123456";

export const CREDS = {
  "InterQL": { code: "111111" },
  "RIDEAU GOOSENECK": { password: "rideau-pw" },
  "OPEN GOOSENECK": { password: "open-pw" },
  "SADM - David": { code: "222222", password: "david-pw" },
  "SADM - Logistique": { code: "333333" },
  "SADM - Éric": "444444",
  "SADM - Jayson": "555555",
  "SADM - Mathieu": "666666",
  "SADM - Quai2go": "777777",
  "SADM - Steve": "888888",
  "Gat - Sam": "999999",
};

export function makeEnv(over = {}) {
  return {
    CARRIER_CREDENTIALS_JSON: JSON.stringify(CREDS),
    SESSION_JWT_SECRET: SECRET,
    ALLOWED_ORIGINS: ORIGIN,
    SUPERUSER_USERNAME: "boss",
    SUPERUSER_PASSWORD_HASH: hashPassword("super-secret-pw"),
    JOB_SERVICE_URL: "http://127.0.0.1:1",
    TRUST_PROXY_HOPS: "1",
    ...over,
  };
}

export function makeConfig(over = {}) {
  const { config, errors } = loadConfig(makeEnv(over));
  if (errors.length) throw new Error(errors.join("; "));
  return config;
}

/** Stand-in for the Railway job service. accounts: username -> password. */
export async function startStub(accounts, { failFor = new Set(), status = 200 } = {}) {
  const calls = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      const { username, password } = JSON.parse(body || "{}");
      calls.push({ method: req.method, url: req.url, username, password });
      if (req.method !== "POST" || req.url !== "/api/auth/mvp-login") { res.writeHead(404).end(); return; }
      if (failFor.has(username) || status !== 200) { res.writeHead(status === 200 ? 500 : status).end("{}"); return; }
      if (accounts[username] !== password) { res.writeHead(401).end('{"error":"bad"}'); return; }
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ accessToken: "job-token:" + username }));
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { url: "http://127.0.0.1:" + server.address().port, calls, close: () => new Promise((r) => server.close(r)) };
}

export const STUB_ACCOUNTS = {
  "RIDEAU GOOSENECK": "rideau-pw",
  "OPEN GOOSENECK": "open-pw",
  "SADM - David": "david-pw",
  "SADM - Éric": "444444",
  "SADM - Jayson": "555555",
  "SADM - Mathieu": "666666",
  "SADM - Quai2go": "777777",
  "SADM - Steve": "888888",
  "Gat - Sam": "999999",
};

let n = 0;
/** Starts the exchange app on an ephemeral port. Each call() gets a fresh fake client IP. */
export async function startApp({ stub, env = {}, now } = {}) {
  const logs = [];
  const config = makeConfig({ JOB_SERVICE_URL: stub ? stub.url : "http://127.0.0.1:1", ...env });
  const server = createApp(config, { now, log: (e, f) => logs.push({ e, ...f }) });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const base = "http://127.0.0.1:" + server.address().port;
  async function call(body, { ip = "10.0.0." + ++n, origin = ORIGIN, method = "POST", path = "/exchange", headers = {}, raw } = {}) {
    const h = { "Content-Type": "application/json", "X-Forwarded-For": ip, ...headers };
    if (origin) h.Origin = origin;
    const res = await fetch(base + path, { method, headers: h, body: method === "POST" ? (raw ?? JSON.stringify(body)) : undefined });
    const text = await res.text();
    let json;
    try { json = JSON.parse(text); } catch { json = undefined; }
    return { status: res.status, json, text, headers: res.headers };
  }
  return { call, logs, config, base, close: () => new Promise((r) => server.close(r)) };
}
