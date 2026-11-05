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
* **Session token.** HS256 JWT, 12 h by default, claims `sub`, `app_role` (carrier / logistique / superuser), `trucks`, `role:"authenticated"`, `aud:"authenticated"`, `exp`. Signed with `SESSION_JWT_SECRET` (a random value you generate; the same value goes into the Supabase edge-function secret `SESSION_JWT_SECRET`, where `quai-data` and `send-transactional-email` verify it). Claims also include `carrier` (readable name) and `names` (the delivery-history labels this login covers). `src/jwt.js` has `verifySession()` for other servers.
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
   * `SESSION_JWT_SECRET`: a random value of 40+ characters you make up (password manager). You will paste the SAME value into Lovable (Cloud -> Secrets) as `SESSION_JWT_SECRET`. It is NOT a Supabase value; never type it in chat.
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


## Data API (replaces Lovable Cloud / Supabase)

The same server now also stores the app's data and sends its emails, so the Lovable Cloud / Supabase
project is no longer needed (see `output/lovable-exit-map.md`). It stays **off** (answers 503) until
`DATABASE_URL` is set, so deploying this code changes nothing by itself.

| Path (kept identical to the Supabase ones, so the Flutter app only needs a new `QUAI_BACKEND_URL`) | What |
|---|---|
| `POST /functions/v1/quai-data` | JSON `{op, ...}`: announcement.*, files.remove, receipt.insert, adjustment.insert, history.upsert, history.list. `?op=upload&bucket=&path=` with the raw picture uploads a file (8 MB, jpeg/png/webp, magic bytes checked). Needs the session token (`X-Quai-Session`). |
| `POST /functions/v1/send-transactional-email` | `receipt-uploaded`, `bol-uploaded`, `order-adjustment`. Recipients are derived on the server from the stored row and must be @groupeql.com; 20 per hour per carrier; idempotency key; suppression list. |
| `GET\|POST /functions/v1/handle-email-unsubscribe` | Unsubscribe page backend (token is the credential). |
| `GET /rest/v1/announcements`, `GET /rest/v1/announcement_images` | Public read of active announcements. |
| `GET /storage/v1/object/public/<bucket>/<path>` | Public pictures (buckets `receipts`, `announcement-images`), served with `nosniff` and a sandbox CSP. |

**Variables:** `DATABASE_URL`, `PUBLIC_BASE_URL`, `PUBLIC_SITE_URL`, `EMAIL_PROVIDER` (resend | sendgrid | log), `EMAIL_API_KEY`, `EMAIL_FROM`, `EMAIL_REPLY_TO` (see `.env.example`). With `EMAIL_PROVIDER=log` nothing is sent.

**Migration (owner approval needed for each step against production):**
1. Add a PostgreSQL service in Railway; set the variables above on this service.
2. `npm run db:schema` (creates the tables; `-- --dry-run` prints the SQL only).
3. Export the old project BEFORE locking it down: `SUPABASE_URL=... SUPABASE_KEY=... npm run db:export -- ./export` (GET requests only; key from the environment, never printed).
4. `NEW_BASE_URL=<PUBLIC_BASE_URL> DATABASE_URL=... npm run db:import -- ./export --dry-run`, then without `--dry-run` (one transaction, safe to repeat; picture links are rewritten to this server).
5. Deploy this server, then build the Flutter app (`config/public-config.json` already points `QUAI_BACKEND_URL` at this server).
6. Only then apply `output/supabase-lockdown.sql` to the old project, and retire it.

Pictures are stored in Postgres (table `files`), so one database backup covers everything.


### Hardening notes (review of PR #4)

* **History rows are owned.** `history.upsert` replaces an existing `delivery_history` row only when that row already carries one of the caller's names (SuperUser: any row). A carrier cannot overwrite or take over another carrier's delivery.
* **Upload quota.** Pictures are stored in Postgres, so each login (SuperUser excepted) may upload 60 files / 150 MB per hour, and one IP 30 uploads per minute (`UPLOAD_MAX_*`). The server logs `storage_alarm` when the total passes `STORAGE_ALARM_MB`. Run `npm run db:schema` again after upgrading (adds `files.uploaded_by` and the unique email-key index; both are idempotent).
* **CORS.** The data routes answer only the origins in `ALLOWED_ORIGINS`. The single wildcard is `GET /storage/v1/object/public/...` (public pictures).
* **Emails.** Each send is claimed atomically (unique idempotency key + per-carrier lock, 20 per hour), so concurrent retries cannot send twice. An email for a receipt without a log row is accepted only for a picture uploaded by the same login. `List-Unsubscribe` points at this server with `List-Unsubscribe-Post: List-Unsubscribe=One-Click`.
* **Heads-up (inherited behaviour):** unsubscribing `sadm@` or `comptabilite@` silences that inbox for everyone who relies on it. Sessions cannot be revoked before they expire (12 h by default): rotate `SESSION_JWT_SECRET` to end all sessions at once.
* **Postgres TLS** is verified by default (see `.env.example`). `DATA_STORE=memory` is refused in production.
* **Exports.** `export/`, `export-*/` are git-ignored: they hold personal data, unsubscribe tokens and receipts.

## Order change notice

A change to a picking ticket is stored as an overlay in Postgres (`order_changes`; the job service / NetSuite have no write endpoint), shown in the app as a "Changed" badge + history, and e-mailed. Routes (session required): `POST /orders/:num/changes`, `POST /orders/:num/changes/preview`, `GET /orders/:num/changes`, `GET /orders/changed?nums=SO1,TO2`, `GET|PUT /orders/division-contacts` (SuperUser).

Migration (NOT applied automatically; owner approval first): `DATABASE_URL=… node scripts/db-schema.js --dry-run`, or run `db/migrations/2026-11-05-order-changes.sql` (idempotent, creates `order_changes` and `division_contacts`).

Variables (all optional):
* `TEST_RECIPIENT_OVERRIDE` — **defaults ON to communication@groupeql.com**: every notice goes there (subject starts with [TEST], the body lists who would have been mailed). Set it to `off` to send to the real divisions, carrier and dispatcher. Only @groupeql.com is accepted.
* `DISPATCHER_EMAIL` — dispatcher/logistics mailbox, default sadm@groupeql.com.
* `ORDER_CHANGE_ROLES` — who may post changes, default `carrier,logistique,superuser`.
* Order change ownership: a carrier may read, preview and change an order only when `delivery_history.carrier_name` or `truck_name` is one of the names on its session (own login, backend user, linked trucks); otherwise 403 `not_your_order`. An order with no delivery_history row is refused to carriers. Logistique and SuperUser act on every order; for an unknown order they only reach the dispatcher + comptabilite fallback (flagged unresolved). Recipients and "old" values come from delivery_history, never from the client. Carriers see roles/divisions in previews, not mailboxes.
