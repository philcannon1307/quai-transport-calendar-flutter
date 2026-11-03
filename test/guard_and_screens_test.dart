import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:intl/date_symbol_data_local.dart";

import "package:quai_calendar/api/auth_service.dart";
import "package:quai_calendar/api/orders_repository.dart";
import "package:quai_calendar/api/session.dart";
import "package:quai_calendar/app.dart";
import "package:quai_calendar/data/carriers.dart";
import "package:quai_calendar/i18n/i18n.dart";
import "package:quai_calendar/l10n/key_map.dart";
import "package:quai_calendar/models/carrier.dart";
import "package:quai_calendar/models/order.dart";
import "package:quai_calendar/screens/admin_screen.dart";
import "package:quai_calendar/screens/calendar_screen.dart";
import "package:quai_calendar/screens/login_screen.dart";
import "package:quai_calendar/screens/my_orders_screen.dart";
import "package:quai_calendar/screens/not_found_screen.dart";
import "package:quai_calendar/screens/unsubscribe_screen.dart";
import "package:quai_calendar/state/providers.dart";

Strings _strings() {
  final values = <String, String>{};
  kOriginalKeyToArb.forEach((dotted, arb) => values[arb] = dotted.split(".").last);
  return Strings.forTests(values);
}

class _CountingAuth implements AuthService {
  int calls = 0;
  @override
  Future<AuthResult> signIn({required Carrier carrier, required String code}) async {
    calls++;
    throw AuthFailure("x");
  }

  @override
  Future<AuthResult> signInSuperUser({required String username, required String password}) async {
    calls++;
    throw AuthFailure("x");
  }
}

Widget _app({SessionStore? store, AuthService? auth}) => ProviderScope(
      overrides: <Override>[
        preloadedStringsProvider.overrideWithValue(_strings()),
        ordersProvider.overrideWith((ref) async => <Order>[]),
        ordersLoadProvider.overrideWith((ref) async => const OrdersLoad()),
        if (store != null) sessionStoreProvider.overrideWithValue(store),
        if (auth != null) authServiceProvider.overrideWithValue(auth),
      ],
      child: const QuaiApp(),
    );

SessionStore _signedIn() {
  final store = MemorySessionStore();
  Session(store).signIn(token: "t", name: "InterQL");
  return store;
}

Future<void> _push(WidgetTester tester, String route) async {
  final nav = tester.state<NavigatorState>(find.byType(Navigator));
  nav.pushNamed(route);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUpAll(initializeDateFormatting);

  group("auth guard", () {
    testWidgets("/calendar with no session redirects to login", (tester) async {
      await tester.pumpWidget(_app());
      await tester.pump();
      await _push(tester, "/calendar");
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(CalendarScreen), findsNothing);
    });

    testWidgets("/my-orders with no session redirects to login", (tester) async {
      await tester.pumpWidget(_app());
      await tester.pump();
      await _push(tester, "/my-orders");
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(MyOrdersScreen), findsNothing);
    });

    testWidgets("with a restored session /calendar and /my-orders render", (tester) async {
      await tester.pumpWidget(_app(store: _signedIn()));
      await tester.pump();
      await _push(tester, "/calendar");
      expect(find.byType(CalendarScreen), findsOneWidget);
      await _push(tester, "/my-orders");
      expect(find.byType(MyOrdersScreen), findsOneWidget);
    });

    testWidgets("a deep link to /calendar keeps a persisted session", (tester) async {
      tester.binding.platformDispatcher.defaultRouteNameTestValue = "/calendar";
      addTearDown(tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);
      await tester.pumpWidget(_app(store: _signedIn()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CalendarScreen), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
    });

    testWidgets("a deep link to /calendar with no session lands on login", (tester) async {
      tester.binding.platformDispatcher.defaultRouteNameTestValue = "/calendar";
      addTearDown(tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);
      await tester.pumpWidget(_app());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(CalendarScreen), findsNothing);
    });

    testWidgets("an expired session sends the user to login with an explanation", (tester) async {
      await tester.pumpWidget(_app(store: _signedIn()));
      await tester.pump();
      await _push(tester, "/calendar");
      expect(find.byType(CalendarScreen), findsOneWidget);
      final container = ProviderScope.containerOf(tester.element(find.byType(CalendarScreen)));
      container.read(sessionExpiredProvider.notifier).state = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byKey(const Key("session-expired")), findsOneWidget);
    });
  });

  group("unknown routes", () {
    testWidgets("an unknown path shows NotFound, not another page", (tester) async {
      await tester.pumpWidget(_app(store: _signedIn()));
      await tester.pump();
      await _push(tester, "/nonexistent");
      expect(find.byType(NotFoundScreen), findsOneWidget);
      expect(find.byType(CalendarScreen), findsNothing);
      expect(find.byKey(const Key("not-found-code")), findsOneWidget);
    });

    testWidgets("an unknown deep link (initial route) shows NotFound", (tester) async {
      tester.binding.platformDispatcher.defaultRouteNameTestValue = "/nonexistent";
      addTearDown(tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);
      await tester.pumpWidget(_app(store: _signedIn()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(NotFoundScreen), findsOneWidget);
    });

    test("routePath ignores query strings and trailing slashes", () {
      expect(routePath("/unsubscribe?token=abc"), "/unsubscribe");
      expect(routePath("/calendar/"), "/calendar");
      expect(routePath(null), "/");
      expect(routePath(""), "/");
    });
  });

  group("/admin", () {
    testWidgets("an empty submit shows field validation and never calls the backend", (tester) async {
      final auth = _CountingAuth();
      await tester.pumpWidget(_app(auth: auth));
      await tester.pump();
      await _push(tester, "/admin");
      expect(find.byType(AdminScreen), findsOneWidget);
      await tester.tap(find.byKey(const Key("admin-submit")));
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const Key("admin-user"))).decoration!.errorText, isNotNull);
      expect(tester.widget<TextField>(find.byKey(const Key("admin-pass"))).decoration!.errorText, isNotNull);
      expect(find.byKey(const Key("admin-error")), findsNothing, reason: "no backend error for an empty form");
      expect(auth.calls, 0);
    });

    testWidgets("typing clears the field error; a filled form does call the backend", (tester) async {
      final auth = _CountingAuth();
      await tester.pumpWidget(_app(auth: auth));
      await tester.pump();
      await _push(tester, "/admin");
      await tester.tap(find.byKey(const Key("admin-submit")));
      await tester.pump();
      await tester.enterText(find.byKey(const Key("admin-user")), "boss");
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const Key("admin-user"))).decoration!.errorText, isNull);
      await tester.enterText(find.byKey(const Key("admin-pass")), "pw");
      await tester.tap(find.byKey(const Key("admin-submit")));
      await tester.pump();
      await tester.pump();
      expect(auth.calls, 1);
    });

    testWidgets("the sign-in page is the light reference style (white, no app bar)", (tester) async {
      await tester.pumpWidget(_app());
      await tester.pump();
      await _push(tester, "/admin");
      expect(find.byType(AppBar), findsNothing);
      final scaffold = tester.widget<Scaffold>(find.descendant(of: find.byType(AdminScreen), matching: find.byType(Scaffold)));
      expect(scaffold.backgroundColor, Colors.white);
    });
  });

  group("/unsubscribe", () {
    testWidgets("renders as the light reference card", (tester) async {
      await tester.pumpWidget(_app());
      await tester.pump();
      await _push(tester, "/unsubscribe?token=abc");
      expect(find.byType(UnsubscribeScreen), findsOneWidget);
      final scaffold = tester.widget<Scaffold>(find.descendant(of: find.byType(UnsubscribeScreen), matching: find.byType(Scaffold)));
      expect(scaffold.backgroundColor, Colors.white);
    });
  });

  test("carrier roster is still available to the guard tests", () {
    expect(carrierByDisplayName("InterQL"), isNotNull);
  });
}
