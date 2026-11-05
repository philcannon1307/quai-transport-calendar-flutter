import { verifySession } from "./jwt.js";
import { allAccounts, carrierByName, normName } from "./roster.js";

// Server-held aggregate of every truck's orders for the Admin screen (SuperUser / Logistique).
//
// The job service (quai-contractor-calendar) serves ONE request at a time at ~4.5 s each (a few
// trucks ~30 s), so the app can no longer fetch 19 trucks in parallel. This module does it for it:
// a background refresher walks the trucks ONE AT A TIME, never overlaps itself, and keeps the
// result in memory (and, when a store is configured, in Postgres so a restart does not start empty).
//
//   GET  /admin/orders-aggregate          -> the snapshot (session role superuser / logistique)
//   POST /admin/orders-aggregate/refresh  -> asks for an immediate refresh (rate limited)
//
// Only truck NAMES, order rows and timestamps leave this module. Passwords, job-service tokens and
// upstream bodies are never logged or returned.

export const AGGREGATE_PATH = "/admin/orders-aggregate";
export const AGGREGATE_REFRESH_PATH = "/admin/orders-aggregate/refresh";
const ALLOWED_ROLES = new Set(["logistique", "superuser"]);
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
const MANUAL_REFRESH_MIN_MS = 60_000;
const TRANSFER_ACCOUNT = /GOOSENECK/i;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class TruckError extends Error {
  constructor(kind, status) {
    super(kind);
    this.kind = kind; // unauthorized | http | timeout | network | too_large | bad_json
    this.status = status;
  }
}

/** The rows of a job-service answer: either a bare array or { orders: [...] }. */
function rowsOf(data) {
  const raw = Array.isArray(data) ? data : data && typeof data === "object" ? data.orders : null;
  if (!Array.isArray(raw)) return [];
  return raw.filter((r) => r && typeof r === "object" && !Array.isArray(r));
}

export function createAdminAggregate({
  config, jobs, store = null, log = () => {}, now = Date.now, fetchImpl = fetch,
  sleepImpl = sleep, retryDelayMs = 3000,
}) {
  const cfg = config.adminAggregate ?? {};
  const intervalMs = (cfg.intervalSeconds ?? 300) * 1000;
  const truckTimeoutMs = cfg.truckTimeoutMs ?? 40_000;
  const enabled = cfg.enabled !== false;
  const base = config.jobServiceUrl;
  const { credentials } = config;

  // One backend account per truck, in roster order (19 trucks). calendar name = the owner's display name.
  const accounts = allAccounts().map((a) => ({
    username: a.username, displayName: a.owner.displayName, truck: a.truck, group: a.owner.group,
    transfers: TRANSFER_ACCOUNT.test(a.username),
  }));

  const passwordFor = (username) => {
    const direct = credentials.get(username);
    if (direct?.password) return direct.password;
    const owner = carrierByName(username);
    return (owner && credentials.get(owner.displayName)?.password) || undefined;
  };

  // username -> { token, ship, transfer, lastRefreshedAt, lastAttemptAt, lastError, failures }
  const state = new Map(accounts.map((a) => [a.username, {
    token: null, ship: [], transfer: [], lastRefreshedAt: null, lastAttemptAt: null, lastError: null, failures: 0,
  }]));
  let running = null; // the in-flight cycle, never two
  let cycleStartedAt = null;
  let cycleFinishedAt = null;
  let lastManualAt = 0;
  let timer = null;
  let stopped = false;
  let persistedAt = null;

  async function getJson(path, token) {
    const url = base + path + "?_=" + now();
    let res;
    try {
      res = await fetchImpl(url, {
        method: "GET",
        headers: { Authorization: "Bearer " + token, Accept: "application/json", "Cache-Control": "no-store", Pragma: "no-cache" },
        redirect: "error",
        signal: AbortSignal.timeout(truckTimeoutMs),
      });
    } catch (e) {
      throw new TruckError(e && e.name === "TimeoutError" ? "timeout" : "network");
    }
    if (res.status === 401 || res.status === 403) throw new TruckError("unauthorized", res.status);
    if (!res.ok) throw new TruckError("http", res.status);
    try {
      const buf = Buffer.from(await res.arrayBuffer());
      if (buf.length > MAX_RESPONSE_BYTES) throw new TruckError("too_large");
      return JSON.parse(buf.toString("utf8"));
    } catch (e) {
      if (e instanceof TruckError) throw e;
      throw new TruckError(e && e.name === "TimeoutError" ? "timeout" : "bad_json");
    }
  }

  async function loginFor(a, st) {
    const pw = passwordFor(a.username);
    if (!pw) throw new TruckError("no_credentials");
    st.token = await jobs.login(a.username, pw);
  }

  /** One truck: ship orders (+ transfer orders for Gooseneck). Re-logs in once on 401/403. */
  async function loadTruck(a, st) {
    let relogged = false;
    const authed = async (path) => {
      if (!st.token) { await loginFor(a, st); relogged = true; }
      try {
        return await getJson(path, st.token);
      } catch (e) {
        if (e instanceof TruckError && e.kind === "unauthorized" && !relogged) {
          relogged = true;
          await loginFor(a, st);
          return getJson(path, st.token);
        }
        throw e;
      }
    };
    const ship = rowsOf(await authed("/api/ship-calendar/orders"));
    const transfer = a.transfers ? rowsOf(await authed("/api/transfer-calendar/orders")).filter((r) => r.isShell !== true) : [];
    return { ship, transfer };
  }

  async function refreshTruck(a) {
    const st = state.get(a.username);
    st.lastAttemptAt = now();
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const out = await loadTruck(a, st);
        st.ship = out.ship; st.transfer = out.transfer;
        st.lastRefreshedAt = now(); st.lastError = null; st.failures = 0;
        return true;
      } catch (e) {
        const kind = e instanceof TruckError ? e.kind : "login_failed"; // jobs.login throws UpstreamError
        st.lastError = kind;
        if (kind === "unauthorized" || kind === "login_failed") st.token = null;
        if (kind === "no_credentials") break;
        if (attempt === 0) await sleepImpl(retryDelayMs);
      }
    }
    st.failures += 1;
    log("admin_aggregate_truck_failed", { truck: a.username, reason: st.lastError, failures: st.failures });
    return false;
  }

  async function cycle(reason) {
    cycleStartedAt = now();
    log("admin_aggregate_cycle_start", { reason });
    let ok = 0;
    let failed = 0;
    let streak = 0;
    for (const a of accounts) {
      if (stopped) break;
      if (await refreshTruck(a)) { ok += 1; streak = 0; } else {
        failed += 1; streak += 1;
        // Backoff: a service that keeps failing is given room to recover instead of being hammered.
        if (streak >= 2) await sleepImpl(Math.min(30_000, retryDelayMs * 2 ** Math.min(streak, 4)));
      }
    }
    cycleFinishedAt = now();
    log("admin_aggregate_cycle_done", { reason, ok, failed, ms: cycleFinishedAt - cycleStartedAt });
    await persist();
  }

  /** Starts one cycle unless one is running. Returns the in-flight promise either way. */
  function refreshNow(reason = "manual") {
    if (running) return running;
    running = cycle(reason).catch((e) => log("admin_aggregate_cycle_error", { message: e && e.message })).finally(() => { running = null; });
    return running;
  }

  async function persist() {
    if (!store?.putAggregateCache) return;
    try {
      await store.putAggregateCache(JSON.stringify(exportState()));
      persistedAt = now();
    } catch {
      log("admin_aggregate_persist_failed");
    }
  }

  const exportState = () => ({
    v: 1,
    trucks: accounts.map((a) => {
      const s = state.get(a.username);
      return { username: a.username, ship: s.ship, transfer: s.transfer, lastRefreshedAt: s.lastRefreshedAt };
    }),
  });

  async function restore() {
    if (!store?.getAggregateCache) return 0;
    try {
      const text = await store.getAggregateCache();
      const data = text ? JSON.parse(text) : null;
      if (!data || data.v !== 1 || !Array.isArray(data.trucks)) return 0;
      let n = 0;
      for (const t of data.trucks) {
        const s = state.get(t?.username);
        if (!s || !Array.isArray(t.ship) || !Array.isArray(t.transfer) || !Number.isFinite(t.lastRefreshedAt)) continue;
        s.ship = t.ship; s.transfer = t.transfer; s.lastRefreshedAt = t.lastRefreshedAt; n += 1;
      }
      if (n) log("admin_aggregate_restored", { trucks: n });
      return n;
    } catch {
      log("admin_aggregate_restore_failed");
      return 0;
    }
  }

  /** Boot: restore the last snapshot, then the first refresh a few seconds later (after /health is up). */
  async function start({ firstDelayMs = 3000 } = {}) {
    if (!enabled || timer || stopped) return;
    await restore();
    const loop = async (delay, reason) => {
      timer = setTimeout(async () => {
        if (stopped) return;
        await refreshNow(reason);
        if (!stopped) loop(intervalMs, "interval");
      }, delay);
      timer.unref?.();
    };
    loop(firstDelayMs, "boot");
  }

  async function stop() {
    stopped = true;
    if (timer) clearTimeout(timer);
    timer = null;
    if (running) await running;
  }

  function truckView(a) {
    const s = state.get(a.username);
    const age = s.lastRefreshedAt == null ? null : now() - s.lastRefreshedAt;
    let status = "failed";
    if (s.lastRefreshedAt == null) status = s.lastAttemptAt == null ? "pending" : "failed";
    else if (s.lastError || age > intervalMs * 3) status = "stale";
    else status = "ok";
    return {
      name: a.username,
      displayName: a.displayName,
      truck: a.truck,
      ok: s.lastRefreshedAt != null && status === "ok",
      status,
      lastRefreshedAt: s.lastRefreshedAt == null ? null : new Date(s.lastRefreshedAt).toISOString(),
      orders: { ship: s.ship, transfer: s.transfer },
    };
  }

  function snapshot() {
    const times = accounts.map((a) => state.get(a.username).lastRefreshedAt).filter((t) => t != null);
    return {
      generatedAt: times.length ? new Date(Math.max(...times)).toISOString() : null,
      oldestRefreshedAt: times.length ? new Date(Math.min(...times)).toISOString() : null,
      refreshing: Boolean(running),
      refreshIntervalSeconds: Math.round(intervalMs / 1000),
      trucks: accounts.map(truckView),
    };
  }

  /** -> { status, body, headers? } ; the caller adds CORS. */
  async function handle(req, url, limiters) {
    const m = /^Bearer\s+(\S+)$/i.exec(String(req.headers.authorization ?? ""));
    const x = req.headers["x-quai-session"];
    let claims = null;
    for (const c of [m ? m[1] : null, typeof x === "string" && x ? x : null]) {
      if (!c) continue;
      claims = verifySession(c, config.sessionSecret, now());
      if (claims) break;
    }
    if (!claims) return { status: 401, body: { error: "unauthorized" } };
    if (!ALLOWED_ROLES.has(claims.app_role)) {
      log("admin_aggregate_forbidden", { carrier: claims.carrier, role: claims.app_role });
      return { status: 403, body: { error: "forbidden" } };
    }
    const wait = limiters.middlewarePerSession.hit("agg:" + String(claims.jti ?? claims.sub));
    if (wait > 0) return { status: 429, body: { error: "too_many_requests", retryAfter: wait }, headers: { "Retry-After": String(wait) } };
    if (!enabled) return { status: 503, body: { error: "aggregate_disabled" } };

    if (url.pathname === AGGREGATE_REFRESH_PATH) {
      if (req.method !== "POST") return { status: 405, body: { error: "method_not_allowed" }, headers: { Allow: "POST, OPTIONS" } };
      if (running) return { status: 202, body: { started: false, refreshing: true } };
      const since = now() - lastManualAt;
      if (since < MANUAL_REFRESH_MIN_MS) {
        const retryAfter = Math.ceil((MANUAL_REFRESH_MIN_MS - since) / 1000);
        return { status: 429, body: { error: "refresh_rate_limited", retryAfter }, headers: { "Retry-After": String(retryAfter) } };
      }
      lastManualAt = now();
      refreshNow("manual");
      return { status: 202, body: { started: true, refreshing: true } };
    }
    if (req.method !== "GET") return { status: 405, body: { error: "method_not_allowed" }, headers: { Allow: "GET, OPTIONS" } };
    return { status: 200, body: snapshot() };
  }

  return { start, stop, refreshNow, snapshot, handle, restore, accounts, idle: () => running ?? Promise.resolve() };
}

export { normName };
