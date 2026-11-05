import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:intl/date_symbol_data_local.dart";
import "package:quai_calendar/api/orders_repository.dart";
import "package:quai_calendar/api/ticket_service.dart";
import "package:quai_calendar/data/carriers.dart";
import "package:quai_calendar/i18n/i18n.dart";
import "package:quai_calendar/l10n/key_map.dart";
import "package:quai_calendar/logic/calendar_views.dart";
import "package:quai_calendar/models/order.dart";
import "package:quai_calendar/screens/calendar_screen.dart";
import "package:quai_calendar/screens/ticket_sheet.dart";
import "package:quai_calendar/state/providers.dart";
import "package:quai_calendar/widgets/logistique_tabs.dart";

Strings _strings() {
  final values = <String, String>{};
  kOriginalKeyToArb
      .forEach((dotted, arb) => values[arb] = dotted.split(".").last);
  return Strings.forTests(values);
}

String _today() => DateTime.now().toIso8601String().substring(0, 10);

final List<Order> _orders = <Order>[
  Order(
      kind: OrderKind.order,
      soNum: "SODELIV",
      date: _today(),
      customer: "Client A",
      serviceType: "Livraison & Installation"),
  Order(
      kind: OrderKind.order,
      soNum: "SOPICK",
      date: _today(),
      customer: "Client B",
      serviceType: "Pick-up"),
  Order(
      kind: OrderKind.transfer,
      soNum: "TO55",
      date: _today(),
      customer: "A → B",
      serviceType: "Transfert / Transfer"),
];

Widget _host(
        {String? carrier,
        OrdersLoad load = const OrdersLoad(),
        List<Override> extra = const <Override>[]}) =>
    ProviderScope(
      overrides: <Override>[
        ordersProvider.overrideWith((ref) async => _orders),
        ordersLoadProvider.overrideWith((ref) async => load),
        currentCarrierProvider.overrideWith((ref) => carrier),
        ...extra,
      ],
      child: StringsScope(
          strings: _strings(),
          child: const MaterialApp(home: CalendarScreen())),
    );

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  // The calendar formats day headings with an explicit locale (fr_CA / en_CA).
  // Without this every test that builds CalendarScreen dies with "Locale data has
  // not been initialized" — all 9 failures in build 4 were exactly that.
  setUpAll(initializeDateFormatting);

  group("SADM - Logistique shows three calendars", () {
    testWidgets("tabs carry the count for each calendar", (tester) async {
      _tall(tester);
      await tester.pumpWidget(_host(carrier: kLogistique));
      await _settle(tester);
      for (final k in <String>["delivInst", "pickups", "transfers"]) {
        final tab = find.byKey(Key("tab-$k"));
        expect(tab, findsOneWidget);
        expect(
            find.descendant(of: tab, matching: find.text("1")), findsOneWidget,
            reason: "count of $k");
      }
    });

    testWidgets("opens on Deliveries & Installations and shows only those",
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(_host(carrier: kLogistique));
      await _settle(tester);
      expect(find.text("SODELIV"), findsOneWidget);
      expect(find.text("SOPICK"), findsNothing);
      expect(find.text("TO55"), findsNothing);
    });

    testWidgets("switching to Pick-ups and TOs filters the cards",
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(_host(carrier: kLogistique));
      await _settle(tester);

      await tester.tap(find.byKey(const Key("tab-pickups")));
      await _settle(tester);
      expect(find.text("SOPICK"), findsOneWidget);
      expect(find.text("SODELIV"), findsNothing);

      await tester.tap(find.byKey(const Key("tab-transfers")));
      await _settle(tester);
      expect(find.text("TO55"), findsOneWidget);
      expect(find.text("SOPICK"), findsNothing);
    });

    testWidgets(
        "says pick-ups are unavailable on that tab when the middleware is not configured",
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(_host(
          carrier: kLogistique,
          load: const OrdersLoad(middlewareUnavailable: true)));
      await _settle(tester);
      expect(find.textContaining("Ramassages indisponibles"), findsNothing);
      await tester.tap(find.byKey(const Key("tab-pickups")));
      await _settle(tester);
      expect(find.textContaining("Ramassages indisponibles"), findsOneWidget);
    });
  });

  group("everyone else", () {
    testWidgets("a normal carrier has no tabs and sees every card",
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(_host(carrier: "Gat - Sam"));
      await _settle(tester);
      expect(find.byType(LogistiqueTabs), findsNothing);
      expect(find.text("SODELIV"), findsOneWidget);
      expect(find.text("SOPICK"), findsOneWidget);
      expect(find.text("TO55"), findsOneWidget);
    });

    testWidgets("the pick-up warning never appears for a normal carrier",
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(_host(
          carrier: "Gat - Sam",
          load: const OrdersLoad(middlewareUnavailable: true)));
      await _settle(tester);
      expect(find.textContaining("Ramassages indisponibles"), findsNothing);
    });
  });

  group("banners", () {
    testWidgets("names the trucks that could not be loaded", (tester) async {
      _tall(tester);
      await tester.pumpWidget(_host(
          carrier: "InterQL",
          load: const OrdersLoad(failedTrucks: <String>["OPEN GOOSENECK"])));
      await _settle(tester);
      expect(find.textContaining("OPEN GOOSENECK"), findsOneWidget);
    });

    testWidgets("a rejected token asks the user to sign in again",
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(_host(
          carrier: "InterQL", load: const OrdersLoad(unauthorized: true)));
      await _settle(tester);
      expect(find.textContaining("Session expirée"), findsOneWidget);
    });
  });

  testWidgets("tapping a card opens that order's picking ticket",
      (tester) async {
    _tall(tester);
    final stuck = TicketService(
      // A future that never completes: no timer left pending when the test ends.
      fetch: (String? t, String n,
              {void Function(double? fraction)? onDownload}) =>
          Completer<TicketHttpResult>().future,
      tokens: _NoTokens(),
    );
    await tester.pumpWidget(_host(
        carrier: "Gat - Sam",
        extra: <Override>[ticketServiceProvider.overrideWithValue(stuck)]));
    await _settle(tester);
    await tester.tap(find.byKey(const Key("card-SODELIV")));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(TicketSheet), findsOneWidget);
    expect(find.byKey(const Key("ticket-title")), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key("ticket-title"))).data,
        "SODELIV");
    await tester.pumpWidget(const SizedBox());
  });

  test("calendar classification keeps the three views distinct", () {
    expect(_orders.map(calendarView).toSet().length, 3);
  });
}

class _NoTokens implements TicketTokens {
  @override
  String? primaryToken() => null;
  @override
  String? transferToken(String toNum) => null;
  @override
  String? carrierName() => null;
  @override
  List<String> sadmTruckTokens() => <String>[];
}
