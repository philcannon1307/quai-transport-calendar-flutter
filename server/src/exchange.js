import { createHash, timingSafeEqual, scryptSync } from "node:crypto";
import { signSession } from "./jwt.js";
import { UpstreamError, mapLimit } from "./jobService.js";
import {
  CARRIERS, LOGISTIQUE, SUPERUSER_NAME, isLogistiqueUnit, allAccounts, backendUsername, carrierByName, loadableLinked,
} from "./roster.js";

/** Constant-time string comparison (hashes first so lengths never leak). */
export function safeEqual(a, b) {
  const ha = createHash("sha256").update(String(a)).digest();
  const hb = createHash("sha256").update(String(b)).digest();
  return timingSafeEqual(ha, hb);
}

function verifyPassword(superUser, password) {
  if (superUser.passwordHash) {
    const [, saltB64, hashB64] = superUser.passwordHash.split("$");
    const expected = Buffer.from(hashB64, "base64");
    const actual = scryptSync(String(password), Buffer.from(saltB64, "base64"), expected.length);
    return timingSafeEqual(actual, expected);
  }
  return safeEqual(password, superUser.password);
}

/**
 * The exchange. Returns { status, body, headers? } and never throws for expected failures.
 * Request shapes (lib/api/auth_service.dart):
 *   carrier:   { "carrier": "<displayName>", "code": "<code>" }
 *   SuperUser: { "carrier": "SuperUser", "username": "...", "code": "<password>" }
 */
export function createExchange({ config, jobs, limiters, log }) {
  const { credentials } = config;

  const passwordFor = (username) => {
    const direct = credentials.get(username);
    if (direct) return direct.password;
    const owner = CARRIERS.find((c) => backendUsername(c) === username);
    return owner ? credentials.get(owner.displayName)?.password : undefined;
  };

  const blocked = (retryAfter) => ({
    status: 429,
    headers: { "Retry-After": String(retryAfter) },
    body: { error: "too_many_attempts", retryAfter },
  });
  const invalid = () => ({ status: 401, body: { error: "invalid_credentials" } });
  const upstream = () => ({ status: 502, body: { error: "upstream_unavailable" } });

  function issue({ carrier, appRole, trucks, names = [], primaryToken, linkedTokens, extra = {} }) {
    const { token, exp } = signSession({ carrier, appRole, trucks, names }, config.sessionSecret, config.sessionTtlSeconds);
    return {
      status: 200,
      body: { accessToken: primaryToken, linkedTokens, role: appRole, sessionToken: token, exp, ...extra },
    };
  }

  async function carrierLogin(name, code, ip) {
    const carrier = carrierByName(name);
    const entry = carrier ? credentials.get(carrier.displayName) : undefined;
    const known = Boolean(carrier && entry);
    const bucket = known ? carrier.displayName : "unknown"; // attacker-chosen names must not create unbounded keys
    const ipKey = ip + "|" + bucket;

    const wait = Math.max(limiters.carrierPerIp.retryAfter(ipKey), limiters.carrierGlobal.retryAfter(bucket));
    if (wait > 0) {
      log("login_blocked", { carrier: bucket, ip, retryAfter: wait });
      return blocked(wait);
    }
    // Always compare, even for unknown carriers, so timing does not reveal the roster.
    const ok = safeEqual(code, known ? entry.code : "\u0000not-a-real-code") && known;
    if (!ok) {
      limiters.carrierPerIp.fail(ipKey);
      limiters.carrierGlobal.fail(bucket);
      log("login_failed", { carrier: bucket, ip });
      return invalid();
    }
    limiters.carrierPerIp.reset(ipKey);

    const primaryUser = backendUsername(carrier);
    const linked = loadableLinked(carrier);
    const accounts = [
      { username: primaryUser, password: passwordFor(primaryUser) ?? entry.password },
      ...linked.map((t) => ({ username: t.displayName, password: passwordFor(t.displayName) })),
    ];
    if (accounts.some((a) => !a.password)) {
      log("config_missing_account", { carrier: name, accounts: accounts.filter((a) => !a.password).map((a) => a.username) });
      return upstream();
    }
    let tokens;
    try {
      tokens = await Promise.all(accounts.map((a) => jobs.login(a.username, a.password)));
    } catch (e) {
      log("upstream_error", { carrier: name, account: e instanceof UpstreamError ? e.account : undefined, reason: e.message });
      return upstream();
    }
    const linkedTokens = {};
    linked.forEach((t, i) => { linkedTokens[t.displayName] = tokens[i + 1]; });
    // Logistique only LOADS the Gooseneck calendars, but opening a picking ticket for another SADM
    // truck's order needs THAT truck's token (the app tries every SADM token on a 404). Best effort:
    // a missing credential or a failed login here never blocks the sign-in.
    if (carrier.displayName === LOGISTIQUE) {
      const loaded = new Set(linked.map((t) => t.displayName));
      const extra = (carrier.linkedTrucks ?? []).filter((t) => !loaded.has(t.displayName) && passwordFor(t.displayName));
      const settled = await Promise.allSettled(extra.map((t) => jobs.login(t.displayName, passwordFor(t.displayName))));
      settled.forEach((r, i) => {
        if (r.status === "fulfilled" && r.value) linkedTokens[extra[i].displayName] = r.value;
        else log("ticket_token_unavailable", { carrier: name, account: extra[i].displayName });
      });
    }
    const appRole = isLogistiqueUnit(carrier.displayName) ? "logistique" : "carrier";
    log("login_ok", { carrier: name, ip, role: appRole });
    return issue({
      carrier: carrier.displayName,
      appRole,
      trucks: [carrier.truck, ...linked.map((t) => t.truck)],
      // Same list the app filters delivery_history by (Dart historyCarrierNames).
      names: [...new Set([carrier.displayName, primaryUser, ...(carrier.linkedTrucks ?? []).map((t) => t.displayName)])],
      primaryToken: tokens[0],
      linkedTokens,
    });
  }

  async function superUserLogin(username, password, ip) {
    const su = config.superUser;
    const ipKey = ip + "|su";
    const wait = Math.max(limiters.superPerIp.retryAfter(ipKey), limiters.superGlobal.retryAfter("su"));
    if (wait > 0) {
      log("superuser_blocked", { ip, retryAfter: wait });
      return blocked(wait);
    }
    if (!su) {
      limiters.superPerIp.fail(ipKey);
      limiters.superGlobal.fail("su");
      return invalid();
    }
    // Evaluate both checks, never short-circuit.
    const userOk = safeEqual(username ?? "", su.username);
    const passOk = verifyPassword(su, password);
    if (!(userOk && passOk)) {
      limiters.superPerIp.fail(ipKey);
      limiters.superGlobal.fail("su");
      log("superuser_failed", { ip });
      return invalid();
    }
    limiters.superPerIp.reset(ipKey);

    const accounts = allAccounts();
    const results = await mapLimit(accounts, 6, async (a) => {
      const pw = passwordFor(a.username);
      if (!pw) return { a, error: "no credentials configured" };
      try {
        return { a, token: await jobs.login(a.username, pw) };
      } catch (e) {
        return { a, error: e.message };
      }
    });
    const good = results.filter((r) => r.token);
    if (good.length === 0) {
      log("upstream_error", { who: SUPERUSER_NAME, reason: results[0]?.error });
      return upstream();
    }
    const unavailable = results.filter((r) => !r.token).map((r) => r.a.username);
    if (unavailable.length) log("superuser_partial", { unavailable });
    const linkedTokens = {};
    for (const r of good) linkedTokens[r.a.username] = r.token;
    log("superuser_ok", { ip, accounts: good.length });
    return issue({
      carrier: SUPERUSER_NAME,
      appRole: "superuser",
      trucks: good.map((r) => r.a.truck),
      primaryToken: good[0].token,
      linkedTokens,
      extra: unavailable.length ? { unavailable } : {},
    });
  }

  return async function exchange(body, ip) {
    if (!body || typeof body !== "object" || Array.isArray(body)) return { status: 400, body: { error: "bad_request" } };
    const { carrier, code, username } = body;
    const okStr = (v, max) => typeof v === "string" && v.length > 0 && v.length <= max;
    if (!okStr(carrier, 80) || !okStr(code, 200) || (username !== undefined && !okStr(username, 200))) {
      return { status: 400, body: { error: "bad_request" } };
    }
    return carrier === SUPERUSER_NAME ? superUserLogin(username, code, ip) : carrierLogin(carrier, code, ip);
  };
}
