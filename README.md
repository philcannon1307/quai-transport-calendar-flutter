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
