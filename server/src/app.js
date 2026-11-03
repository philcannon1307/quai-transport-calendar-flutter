import http from "node:http";
import { FailureLimiter, RateLimiter } from "./limiter.js";
import { createJobService } from "./jobService.js";
import { createExchange } from "./exchange.js";
import { createMiddlewareProxy, MIDDLEWARE_PATH } from "./middleware.js";

const MAX_BODY = 4096;

export function clientIp(req, hops) {
  const xff = String(req.headers["x-forwarded-for"] ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (hops > 0 && xff.length >= hops) return xff[xff.length - hops]; // the address our own proxy saw
  return req.socket.remoteAddress ?? "unknown";
}

export function createApp(config, { jobs, now = Date.now, log = () => {} } = {}) {
  const L = config.limits;
  const limiters = {
    perIp: new RateLimiter({ ...L.perIpRequests, now }),
    carrierPerIp: new FailureLimiter({ ...L.carrierPerIp, now }),
    carrierGlobal: new FailureLimiter({ ...L.carrierGlobal, now }),
    superPerIp: new FailureLimiter({ ...L.superPerIp, now }),
    superGlobal: new FailureLimiter({ ...L.superGlobal, now }),
    middlewarePerIp: new RateLimiter({ ...L.middlewarePerIp, now }),
    middlewarePerSession: new RateLimiter({ ...L.middlewarePerSession, now }),
  };
  const jobService = jobs ?? createJobService({ baseUrl: config.jobServiceUrl, timeoutMs: config.jobTimeoutMs });
  const exchange = createExchange({ config, jobs: jobService, limiters, log });
  const middleware = createMiddlewareProxy({ config, limiters, log, now });

  function send(res, status, body, extra = {}) {
    const text = body === undefined ? "" : JSON.stringify(body);
    res.writeHead(status, {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...extra,
    });
    res.end(text);
  }

  function readBody(req) {
    return new Promise((resolve, reject) => {
      let size = 0;
      let tooLarge = false;
      const chunks = [];
      req.on("data", (c) => {
        size += c.length;
        if (tooLarge) return; // keep discarding; the response below closes the connection
        if (size > MAX_BODY) {
          tooLarge = true;
          chunks.length = 0;
          reject(Object.assign(new Error("too large"), { status: 413 }));
          return;
        }
        chunks.push(c);
      });
      req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
      req.on("error", reject);
    });
  }

  return http.createServer(async (req, res) => {
    try {
      const path = (req.url ?? "/").split("?")[0];
      if (req.method === "GET" && path === "/health") return send(res, 200, { status: "ok" });
      const isMiddleware = path === MIDDLEWARE_PATH;
      if (path !== "/exchange" && path !== "/" && !isMiddleware) return send(res, 404, { error: "not_found" });

      // CORS: a browser Origin must be on the allow-list; no Origin = not a browser.
      const origin = req.headers.origin;
      const cors = {};
      if (origin !== undefined) {
        if (!config.allowedOrigins.has(origin)) return send(res, 403, { error: "origin_not_allowed" });
        Object.assign(cors, { "Access-Control-Allow-Origin": origin, Vary: "Origin" });
      }
      if (req.method === "OPTIONS") {
        return send(res, 204, undefined, {
          ...cors,
          "Access-Control-Allow-Methods": isMiddleware ? "GET, OPTIONS" : "POST, OPTIONS",
          "Access-Control-Allow-Headers": isMiddleware ? "Authorization, X-Quai-Session, Cache-Control, Content-Type" : "Content-Type",
          "Access-Control-Max-Age": "600",
        });
      }
      if (isMiddleware) {
        if (req.method !== "GET") return send(res, 405, { error: "method_not_allowed" }, { ...cors, Allow: "GET, OPTIONS" });
        const mip = clientIp(req, config.trustProxyHops);
        const mwait = limiters.middlewarePerIp.hit(mip);
        if (mwait > 0) return send(res, 429, { error: "too_many_requests", retryAfter: mwait }, { ...cors, "Retry-After": String(mwait) });
        const out = await middleware(req, new URL(req.url ?? "/", "http://x"), mip);
        if (out.raw !== undefined) {
          res.writeHead(out.status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...cors });
          return res.end(out.raw);
        }
        return send(res, out.status, out.body, { ...cors, ...(out.headers ?? {}) });
      }
      if (req.method !== "POST") return send(res, 405, { error: "method_not_allowed" }, { ...cors, Allow: "POST, OPTIONS" });

      const ip = clientIp(req, config.trustProxyHops);
      const wait = limiters.perIp.hit(ip);
      if (wait > 0) return send(res, 429, { error: "too_many_requests", retryAfter: wait }, { ...cors, "Retry-After": String(wait) });

      if (!String(req.headers["content-type"] ?? "").toLowerCase().startsWith("application/json")) {
        return send(res, 415, { error: "unsupported_media_type" }, cors);
      }
      let parsed;
      try {
        parsed = JSON.parse(await readBody(req));
      } catch (e) {
        if (e.status === 413) return send(res, 413, { error: "payload_too_large" }, { ...cors, Connection: "close" });
        return send(res, 400, { error: "bad_request" }, cors);
      }
      const out = await exchange(parsed, ip);
      return send(res, out.status, out.body, { ...cors, ...(out.headers ?? {}) });
    } catch (e) {
      log("unhandled_error", { message: e && e.message });
      if (!res.headersSent) send(res, 500, { error: "server_error" });
      else res.end();
    }
  });
}
