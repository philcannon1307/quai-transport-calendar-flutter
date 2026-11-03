// Client for the Railway job service: POST /api/auth/mvp-login {username,password} -> {accessToken}.

export class UpstreamError extends Error {
  constructor(message, account) {
    super(message);
    this.account = account;
  }
}

export function createJobService({ baseUrl, timeoutMs, fetchImpl = fetch }) {
  async function login(username, password) {
    let res;
    try {
      res = await fetchImpl(baseUrl + "/api/auth/mvp-login", {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ username, password }),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch {
      throw new UpstreamError("job service unreachable", username);
    }
    if (!res.ok) throw new UpstreamError("job service answered " + res.status, username);
    let json;
    try {
      json = await res.json();
    } catch {
      throw new UpstreamError("job service returned invalid JSON", username);
    }
    const token = json && json.accessToken;
    if (typeof token !== "string" || !token) throw new UpstreamError("job service returned no accessToken", username);
    return token;
  }
  return { login };
}

/** Runs fn over items with at most `limit` in flight; keeps result order. */
export async function mapLimit(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i], i);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}
