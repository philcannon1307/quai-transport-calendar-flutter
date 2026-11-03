# Quai token-exchange service

The small server the Flutter app signs in through. The app sends a person's name and code; this
service checks them, logs in to the Railway job service for that person's truck(s) and hands back the
job-service tokens plus a signed session token. **No passwords exist in the app.** They live only in this
service's environment variables.

Plain Node.js, zero third-party dependencies, one file per concern (`src/`).

## What it does

| Call | Body | Success (200) |
|---|---|---|
| `POST /exchange` (carrier) | `{"carrier":"InterQL","code":"…"}` | `{"accessToken","linkedTokens":{"<truck account>":"<token>"},"role":"carrier\|logistique","sessionToken","exp"}` |
| `POST /exchange` (admin) | `{"carrier":"SuperUser","username":"…","code":"<password>"}` | same shape, `role:"superuser"`, `linkedTokens` for **every** truck account (+ `unavailable:[…]` if some could not be logged in) |
| `GET /middleware/events?location=…&from=YYYY-MM-DD&to=YYYY-MM-DD` | header `Authorization: Bearer <sessionToken>` (role `logistique` or `superuser`) | the middleware's JSON unchanged, e.g. `{"events":[…]}` (Pick-ups tab) |
| `GET /health` | – | `{"status":"ok"}` |

Errors: `401 invalid_credentials` (same body for wrong code, unknown person, missing config), `429 too_many_attempts` with a `Retry-After` header, `400` bad input, `403` origin not allowed, `413` body over 4 KB, `415` not JSON, `502 upstream_unavailable` (job service down or rejecting the stored password: a configuration problem, **not** the user's fault).

* **Scoped tokens.** A person only gets tokens for their own truck(s): InterQL = RIDEAU + OPEN GOOSENECK (trucks 3, 4); SADM - Logistique = SADM - David + both Gooseneck trucks; everyone else = one truck. Only SuperUser gets all.
* **Session token.** HS256 JWT, 12 h by default, claims `sub`, `app_role` (carrier / logistique / superuser), `trucks`, `role:"authenticated"`, `aud:"authenticated"`, `exp`. Signed with `SESSION_JWT_SECRET`; use your Supabase JWT secret so row-level security can read `auth.jwt() ->> 'app_role'`. `src/jwt.js` has `verifySession()` for other servers.
* **The role comes from here.** The app trusts `role` only from this response.

## Pick-ups proxy (`GET /middleware/events`)

The SADM - Logistique Pick-ups tab reads Ste-Agathe calendar events from the after-sales middleware, which needs an `x-api-key`. The key lives only here (`MIDDLEWARE_API_KEY`).

* **Who:** a valid, unexpired session token (Authorization bearer; `X-Quai-Session` also accepted) whose role is `logistique` or `superuser`. Carriers get 403, anything unverifiable 401.
* **What is forwarded:** exactly one upstream call, `GET <MIDDLEWARE_URL>/api/netsuite/events`, with `location` (1-60 chars), `from` and `to` (`YYYY-MM-DD`, to >= from, at most 120 days). Any other parameter is refused with 400; no caller header, cookie or token is passed on; redirects are not followed. Other methods 405, other paths 404.
* **Answers:** upstream JSON returned unchanged (200). Upstream error, non-JSON, over 4 MB, timeout (`MIDDLEWARE_TIMEOUT_MS`, default 15 s) or network failure -> `502 {"error":"upstream_unavailable"}` with no upstream detail. No key configured -> `503 middleware_not_configured`.
* **Limits:** 60 requests/min per session, 120/min per IP (429 + `Retry-After`).
* **CORS:** same exact-origin list as the login (`ALLOWED_ORIGINS`); preflight allows `GET` with `Authorization`, `X-Quai-Session`, `Cache-Control`.
* **Logs:** event names only (`middleware_upstream_status`, `middleware_upstream_error` with kind timeout/network). The key is never logged or echoed.

## Security

* Passwords only in environment variables (`CARRIER_CREDENTIALS_JSON`, `SUPERUSER_PASSWORD_HASH`). Nothing in the repo or in the app. Secrets are never logged or returned; failed-login logs hold the carrier name and IP only.
* Brute force (a 6-digit code has only a million values): 5 wrong codes per carrier per IP in 10 min = 15 min lock; 20 wrong codes per carrier from anywhere in 1 h = 30 min lock; 30 requests/min per IP; SuperUser: 3 wrong per IP = 30 min lock, 10 from anywhere = 1 h lock. A locked login is refused **before** the code is checked, even if the code is right. Constant-time comparisons. Limits are in memory, so **run exactly one instance** (`railway.json` pins 1 replica).
* A global lock means someone guessing can temporarily block a driver's login (15 to 30 min). That trade-off is deliberate; the real defence for codes is length. Prefer longer codes if you can.
* CORS: only the exact origins in `ALLOWED_ORIGINS`; any browser request from another site is refused.
* The service refuses to start when the configuration is wrong, and says which setting (never the value).
* After going live: change every carrier password and the SuperUser password. The old React app still has the old ones in its bundle.

## Deploy on Railway (no coding needed)

You need: a Railway account, access to the GitHub repo, and the list of passwords (ask the person who runs the job service).

1. **New service.** Railway -> your project -> **New** -> **GitHub Repo** -> pick `quai-transport-calendar-flutter` (after the pull request with this folder is merged, branch `main`).
2. **Point it at this folder.** Open the new service -> **Settings** -> **Source** -> **Root Directory** = `/server`. Railway then finds the `Dockerfile` and `railway.json` here by itself.
3. **Add the settings.** Service -> **Variables** -> **Raw Editor**. Paste the lines from `.env.example` and replace every `CHANGE-ME`:
   * `CARRIER_CREDENTIALS_JSON`: one line of JSON. Add one entry per person in the app's login list plus the truck accounts, see the list below. Check it is valid JSON at jsonlint.com **without the real passwords**, or add the entries one at a time.
   * `SESSION_JWT_SECRET`: your Supabase project's JWT secret (Supabase -> Project Settings -> API -> JWT Secret).
   * `MIDDLEWARE_API_KEY`: the key of the after-sales middleware (`quai-backend-methods`). Ask whoever runs it. Without it everything works except the Pick-ups tab, which shows "unavailable".
   * `ALLOWED_ORIGINS`: the web address of the app (and any other place it is shown), exactly, e.g. `https://your-app.web.app`.
   * `SUPERUSER_USERNAME` and either `SUPERUSER_PASSWORD_HASH` (best) or `SUPERUSER_PASSWORD`. To make a hash: on a computer with Node.js, open a terminal in the `server` folder, run `npm run hash-password`, type the password and paste the printed `scrypt$…` line.
4. **Get a public address.** **Settings** -> **Networking** -> **Generate Domain**. You get `https://something.up.railway.app`.
5. **Deploy and check.** Railway builds automatically. Open `https://something.up.railway.app/health`: it must show `{"status":"ok"}`. If the deploy fails, open **Deployments -> View logs**: the lines starting with `config_error` say which setting to fix.
6. **Tell the app.** The Flutter app is built with the address `https://something.up.railway.app/exchange` as `QUAI_EXCHANGE_URL`. Give it to the person who builds the app. That one address also configures the Pick-ups tab (the app derives `https://something.up.railway.app/middleware/events` from it).
7. **Pick-ups check.** Sign in as SADM - Logistique and open the Pick-ups tab: events appear. If it says "unavailable", look in the Railway logs for `middleware_not_configured` (key missing) or `middleware_upstream_status` (the middleware refused the key).
8. **Test a login** in the app with a real carrier. Wrong code should say "Identifiants incorrects"; the right one should show the calendar.

Do **not** add more instances (replicas); the lockouts live in memory.

### Names for `CARRIER_CREDENTIALS_JSON`

Login list: `SADM - David`, `SADM - Éric`, `SADM - Jayson`, `SADM - Mathieu`, `SADM - Quai2go`, `SADM - Steve`, `Gat - Sam`, `Lindsay - Brendan`, `Lindsay - Cole`, `Lindsay - Laurent`, `Mt-Laurier - Steve`, `Québec - Justin`, `Québec - Marc`, `Sherbrooke - Hervé`, `InterQL`, `DA TRANSPORT`, `LANCEZ TRANSPORT`, `SD PRESTIGE`, `SADM - Logistique`.
Truck accounts also needed: `RIDEAU GOOSENECK`, `OPEN GOOSENECK`.

Each value is either a string (the code the person types is also the truck's password) or `{"code":"…","password":"…"}` when the typed code differs from the truck's job-service password. Rules:
* A person's typed code = their entry's `code`. Their truck password = the entry named like their **truck account**'s `password` (for InterQL that is `RIDEAU GOOSENECK`, for SADM - Logistique that is `SADM - David`).
* People without an entry cannot sign in (a warning is logged at start-up). SuperUser needs an entry for **every** truck account; accounts without one are listed in `unavailable`.

## Local development

```
cd server
cp .env.example .env     # then edit; load it however you like, e.g.:  set -a; . ./.env; set +a
npm test                 # unit + integration tests, no network, no dependencies to install
npm start
```

Tests include an integration suite against a stub of the job service (`test/exchange.test.js`, `test/security.test.js`) that asserts the exact JSON the Flutter `TokenExchangeAuthService` sends and reads, and a drift check that fails if `src/roster.js` and `lib/data/carriers.dart` disagree.

## Keeping it in sync

The roster in `src/roster.js` is a copy of `lib/data/carriers.dart` (display names, groups, truck ids, linked trucks). Change both together; `npm test` fails otherwise.
