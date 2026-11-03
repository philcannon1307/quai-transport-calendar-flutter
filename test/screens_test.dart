import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:intl/date_symbol_data_local.dart";

import "package:quai_calendar/i18n/i18n.dart";
import "package:quai_calendar/l10n/key_map.dart";
import "package:quai_calendar/models/order.dart";
import "package:quai_calendar/screens/calendar_screen.dart";
import "package:quai_calendar/screens/my_orders_screen.dart";
import "package:quai_calendar/state/providers.dart";

/// NOTE ON PUMPING: these screens show a CircularProgressIndicator while the
/// orders future is in flight. That animation never stops, so pumpAndSettle()
/// times out rather than failing on an assertion — it did, once. Pump a fixed
/// number of frames instead; it is deterministic and far faster.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

/// Minimal dictionary keyed the way Strings expects (ARB identifiers).
Strings _strings() {
  final values = <String, String>{};
  kOriginalKeyToArb.forEach((dotted, arb) => values[arb] = dotted.split(".").last);
  return Strings.forTests(values);
}

Widget _host(Widget child, List<Order> orders) {
  return ProviderScope(
    overrides: <Override>[
      ordersProvider.overrideWith((ref) async => orders),
    ],
    child: StringsScope(
      strings: _strings(),
      child: MaterialApp(home: child),
    ),
  );
}

/// A tall viewport so day sections and their cards are laid out, not clipped
/// off the bottom of the default 800x600 test window.
void useTallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

String _iso(DateTime d) => d.toIso8601String().substring(0, 10);

Order _order({
  required String soNum,
  required String date,
  String service = "Livraison",
  OrderKind kind = OrderKind.order,
}) =>
    Order(kind: kind, soNum: soNum, date: date, serviceType: service, customer: "Client " + soNum);

void main() {
  setUpAll(initializeDateFormatting);

  testWidgets("calendar renders a day section with its order card", (tester) async {
    useTallScreen(tester);
    final iso = _iso(DateTime.now());
    await tester.pumpWidget(_host(const CalendarScreen(), <Order>[_order(soNum: "SO1001", date: iso)]));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(SegmentedButton<int>), findsOneWidget);
    expect(find.text("SO1001"), findsOneWidget);
  });

  testWidgets("calendar renders a transfer card with its TO badge", (tester) async {
    useTallScreen(tester);
    final iso = _iso(DateTime.now());
    await tester.pumpWidget(_host(
      const CalendarScreen(),
      <Order>[_order(soNum: "TO777", date: iso, service: "Transfert / Transfer", kind: OrderKind.transfer)],
    ));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text("TO777"), findsOneWidget);
    expect(find.text("TO"), findsOneWidget);
  });

  testWidgets("calendar survives an empty day with no orders", (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(_host(const CalendarScreen(), <Order>[]));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(SegmentedButton<int>), findsOneWidget);
  });

  testWidgets("Mes commandes shows upcoming work and hides the past", (tester) async {
    useTallScreen(tester);
    final now = DateTime.now();
    await tester.pumpWidget(_host(const MyOrdersScreen(), <Order>[
      _order(soNum: "SOUPCOMING", date: _iso(now.add(const Duration(days: 2)))),
      _order(soNum: "SOPAST", date: _iso(now.subtract(const Duration(days: 9)))),
    ]));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text("SOUPCOMING"), findsOneWidget);
    expect(find.text("SOPAST"), findsNothing);
  });

  testWidgets("Mes commandes hides work beyond the one-week window", (tester) async {
    useTallScreen(tester);
    final far = _iso(DateTime.now().add(const Duration(days: 11)));
    await tester.pumpWidget(_host(const MyOrdersScreen(), <Order>[_order(soNum: "SOFAR", date: far)]));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text("SOFAR"), findsNothing);
  });
}
