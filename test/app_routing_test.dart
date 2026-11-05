import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:intl/date_symbol_data_local.dart";

import "package:quai_calendar/api/orders_repository.dart";
import "package:quai_calendar/api/session.dart";
import "package:quai_calendar/app.dart";
import "package:quai_calendar/i18n/i18n.dart";
import "package:quai_calendar/l10n/key_map.dart";
import "package:quai_calendar/models/order.dart";
import "package:quai_calendar/screens/calendar_screen.dart";
import "package:quai_calendar/screens/login_screen.dart";
import "package:quai_calendar/state/providers.dart";

Strings _strings() {
  final values = <String, String>{};
  kOriginalKeyToArb
      .forEach((dotted, arb) => values[arb] = dotted.split(".").last);
  return Strings.forTests(values);
}

Widget _app({SessionStore? store}) => ProviderScope(
      overrides: <Override>[
        preloadedStringsProvider.overrideWithValue(_strings()),
        ordersProvider.overrideWith((ref) async => <Order>[]),
        ordersLoadProvider.overrideWith((ref) async => const OrdersLoad()),
        if (store != null) sessionStoreProvider.overrideWithValue(store),
      ],
      child: const QuaiApp(),
    );

void main() {
  setUpAll(initializeDateFormatting);

  testWidgets("QuaiApp builds exactly one MaterialApp on the first frame",
      (tester) async {
    // REGRESSION: app.dart used to render a loading MaterialApp while the
    // dictionary future resolved, then build a second one. The swap reset the
    // Navigator to "/", so /#/calendar and every page refresh landed on login.
    await tester.pumpWidget(_app());
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets("named routes resolve to their screens (signed in)",
      (tester) async {
    final store = MemorySessionStore();
    Session(store).signIn(token: "t", name: "InterQL");
    await tester.pumpWidget(_app(store: store));
    await tester.pump();
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.pushNamed("/calendar");
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(CalendarScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
