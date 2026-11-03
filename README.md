# Quai Lafantaisie — Transport Calendar (Flutter)

Flutter Web port of the Quai Lafantaisie transport calendar used by carriers and
dispatch. Replaces the React app `quai-calendar-connect` (reference only — do not
push here).

Live preview: https://cb-eizwphr4mvsyclijai8x--preview-l3lvpbdx.web.app

## Build contract

The platform runner executes `build.js`, which **self-provisions the Flutter SDK**
(no SDK in the image, nothing to install by hand) and then:

1. `flutter pub get`
2. `flutter test` — **gate: a failing test fails the build**
3. `flutter build web --release` → output in `build/web`

`npm run build` is the single entry point. There are no lifecycle scripts.
Typical timings: tests ~40 s, web compile ~78 s, ~121 s total.

## Tests (the gate)

| File | Covers |
| --- | --- |
| `test/carriers_test.dart` | carrier roster, retired-account purge |
| `test/adjustment_inbox_test.dart` | 12-case group → inbox routing matrix |
| `test/interql_test.dart` | InterQL trucks 3 + 4 |
| `test/logistique_test.dart` | SADM-Logistique dispatcher behaviour |
| `test/order_windows_test.dart` | three-calendar classification, business-day rollover (02:00) |
| `test/api_client_test.dart` | cache-busted request URLs |
| `test/i18n_keys_test.dart` | **every `.t("…")` key exists in the dictionary** |
| `test/screens_test.dart` | calendar day sections, order + transfer cards, "Mes commandes" window |

Two of these exist because of defects found during the port, and are regression
guards rather than decoration:

- **`i18n_keys_test.dart`** — eight invented translation keys shipped to a preview;
  one rendered as the literal text `login.code` where a French label belonged.
  This test fails the build if any key used in `lib/` is missing from the dictionary.
- **`screens_test.dart`** — `_OrderCard` used `Row(crossAxisAlignment: stretch)`
  with no bounded height inside the day `ListView`, corrupting parent data during
  layout. It crashed on the first order card. Fixed with `IntrinsicHeight`.

## Picking tickets, contacts, InterQL, Logistique

| Area | Where | Rule ported |
| --- | --- | --- |
| Ticket viewer | `screens/ticket_sheet.dart`, `api/ticket_service.dart` | progress that eases to 70% while NetSuite builds the PDF; 10-min cache; print / download; big red **Fermer / Close**; owning-truck token only; a 404 is retried once; 401/403 = stale session |
| Contact links | `logic/contact_parser.dart`, `api/contact_service.dart`, `widgets/contact_links.dart` | ship-to phone + address parsed from the PDF text (template 146); max 2 PDFs processed at once; result cached; Call + Directions buttons |
| InterQL (trucks 3+4) | `api/orders_repository.dart` | one login covers both trucks; separate events on one SO are kept (dedupe by event, never by SO); each TO remembers the token of the Gooseneck truck that owns it |
| SADM - Logistique | `orders_repository.dart`, `widgets/logistique_tabs.dart` | 3 tabs with counts; loads only the two Gooseneck trucks; pick-ups from the Ste-Agathe middleware; parallel-token picking lists on a 404 |

**PDF engine isolation.** `pdfrx` and `printing` are imported by exactly one file,
`lib/pdf/pdfrx_impl.dart`, which only `main.dart` imports and injects through providers.
No test and no other file loads a PDF engine.

**Middleware (pick-ups).** The reference app shipped the middleware `x-api-key` in the
web bundle. This port never holds it: it calls the proxy built into the exchange server
(`GET /middleware/events`, `server/src/middleware.js`) with the session token. The proxy URL is
derived from `QUAI_EXCHANGE_URL` (one dart-define for sign-in and pick-ups; optional override
`QUAI_MIDDLEWARE_PROXY_URL`). Without an exchange URL, or without `MIDDLEWARE_API_KEY` on the server, the Pick-ups tab
says so instead of showing an empty list.

**Do not upgrade `pdfrx` to 2.x.** It pulls `pdfium_dart`, whose native-assets hook needs
a C compiler during `flutter test`. The platform build host has none, so the test gate fails
with "No compiler configured on host 'linux_x64'". `pdfrx` is pinned to `^1.3.5`.

## URL strategy — do not "fix" this

`main.dart` keeps Flutter's **default hash strategy** (`/#/calendar`).
`usePathUrlStrategy()` was tried and reverted: this Firebase Hosting site has no
SPA rewrite, so `/calendar` returns the hosting 404 page and the app never boots
(verified on v8). Clean paths require a hosting rewrite of all paths to
`index.html` — a platform change, not an app change.

## Firebase / secrets

No credentials in this repository. `firebaseConfig` placeholders are injected at
deploy time. The Crewdle API key is bound by the platform at deploy and read at
runtime as `process.env.CREWDLE_API_KEY` — never committed, never logged.

## Pending — NOT delivered

0. **Middleware proxy** for Logistique pick-ups — built (exchange server, PR #2); live only once the server is deployed with `MIDDLEWARE_API_KEY` and the app is built with `QUAI_EXCHANGE_URL`.
   **PDF rendering, text extraction, print and download are untested in a real browser**
   (they need a signed-in session to fetch a real ticket); only their surrounding behaviour
   is covered by tests.

1. **Server-side token exchange is missing.** `authServiceProvider` returns
   `UnimplementedAuthService` until `QUAI_EXCHANGE_URL` is supplied, so **sign-in
   fails by design** and no live order data is reachable. The Railway endpoint is
   the blocker.
2. **The calendar and "Mes commandes" have never been verified in a browser** —
   they sit behind that sign-in. Their rendering and filtering are proven by
   `screens_test.dart` against the real widget tree, which is not the same claim
   as "seen". No sample data was seeded to fake a working screen.
3. **Railway code** for the exchange endpoint is not written.
4. **Security:** the legacy React bundle exposes a middleware API key that needs
   rotating; it is not reused here.


## Session, roles and what the client trusts (review fixes)

- **Persistent session.** `lib/api/prefs_session_store.dart` (shared_preferences: localStorage on web) is wired in `main.dart`. It stores ONLY the access tokens, the display name, the **role** and the **session JWT** returned by the token exchange. It never stores a password or a carrier code. A refresh, a new tab and a deep link (`/#/calendar`) keep the session. Logout clears everything. The retired-account purge still runs on restore. If storage is blocked (private mode) the app falls back to an in-memory session.
- **Route guard.** `/calendar` and `/my-orders` go through `AuthGuard`: no session, or an expired one, redirects to the login screen. Unknown paths show a NotFound screen (reference: pages/NotFound.tsx). There is one route table (`onGenerateRoute`), also used for the initial URL.
- **Expired token.** A 401/403 from the job service is never shown as an empty calendar: `ApiClient.fetchShipCalendarOrders` and `shipOrders` throw `UnauthorizedException`; `ordersLoadProvider` clears the session and the login screen says "Session expirée".
- **SuperUser comes from the server.** `Session.isSuperUser` is true only when the exchange response said `role: "superuser"` (`signInSuperUser` rejects any other response). It is a UI hint: hiding the admin screen is not a security control. Every privileged write must be enforced server-side from the signed session JWT (see output/server-contract.md).
- **No client-chosen recipients.** The client sends ids only: `order-adjustment` gets `{reportId, orderNum}`; `receipt-uploaded` / `bol-uploaded` get `{receiptId, storagePath, kind}`. The server loads the row, computes recipients (group inbox; transfers to both stores; groupeql.com only; receipts to comptabilite@, BOL to sadm@) and sends. The session JWT is the `Authorization: Bearer` of every Supabase call once signed in (`apikey` stays the public key; signed out, the bearer falls back to the public key = read-only announcements), so Postgres RLS and Storage see the carrier. The email call also carries it as `X-Quai-Session`. Change reports log `transfer_locations` on the `order_adjustments` row (transfers only) so the server can email both stores. The history snapshot is `POST /rest/v1/rpc/upsert_delivery_history {rows: [...]}`. SQL and function code: `output/supabase-rls.sql`, `output/send-transactional-email-patch.md`; steps in `output/supabase-apply-steps.md`.

### Known limitation: receipts bucket
Receipt, BOL and change-report photos are uploaded to the `receipts` bucket and referenced by a **public URL** with an unguessable UUID path. They can contain personal data. Preferred end state: private bucket + short-lived signed URLs minted by the server when it builds the email. Until then the URL is the only protection.

### 02:00 past-card rule (owner-mandated)
Cards turn red (past) after **02:00 local time** (rolling working day, `lib/logic/order_windows.dart`), not at midnight. This was decided by the owner. The old React source has no explicit `setHours`: it compares plain dates (`shipDate < todayISO()`). **Future parity checks must not "fix" this**; keep the code and tests (`test/order_windows_test.dart`).

### Styling notes (match the reference)
Only the Login page is dark navy. `/admin` (sign-in) and `/unsubscribe` are light pages with a bordered card, exactly like the reference's Admin.tsx and Unsubscribe.tsx. The EN brand name "Lafantaisie Dock" is the reference's own `brand.name` (FR: "Quai Lafantaisie").
