import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:intl/date_symbol_data_local.dart";

import "package:quai_calendar/i18n/i18n.dart";
import "package:quai_calendar/l10n/key_map.dart";
import "package:quai_calendar/logic/calendar_week.dart";
import "package:quai_calendar/models/order.dart";
import "package:quai_calendar/screens/calendar_screen.dart";
import "package:quai_calendar/state/providers.dart";
import "package:quai_calendar/theme.dart";
import "package:quai_calendar/widgets/status_chip.dart";

Strings _strings() {
  final values = <String, String>{};
  kOriginalKeyToArb
      .forEach((dotted, arb) => values[arb] = dotted.split(".").last);
  return Strings.forTests(values);
}

String _iso(DateTime d) => d.toIso8601String().substring(0, 10);

Order _o(String so, DateTime d,
        {String? status,
        String service = "Livraison & Installation",
        String customer = "Pierre"}) =>
    Order(
        kind: OrderKind.order,
        soNum: so,
        date: _iso(d),
        customer: customer,
        serviceType: service,
        eventStatus: status,
        city: "Gatineau");

Widget _host(Widget child, List<Order> orders) => ProviderScope(
      overrides: <Override>[
        ordersProvider.overrideWith((ref) async => orders),
        currentCarrierProvider.overrideWith((ref) => "Gat - Sam"),
      ],
      child: StringsScope(
          strings: _strings(),
          child: MaterialApp(theme: buildTheme(), home: child)),
    );

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  await t.pump(const Duration(milliseconds: 50));
}

void _size(WidgetTester t, double w, double h) {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

void main() {
  setUpAll(initializeDateFormatting);

  group("status decoding", () {
    test("NetSuite event status -> chip status", () {
      expect(statusOf(_o("A", DateTime(2026, 11, 4), status: "CONFIRMED")),
          QuaiStatus.confirmed);
      expect(statusOf(_o("A", DateTime(2026, 11, 4), status: "Tentative")),
          QuaiStatus.tentative);
      expect(statusOf(_o("A", DateTime(2026, 11, 4), status: "PROVISOIRE")),
          QuaiStatus.tentative);
      expect(statusOf(_o("A", DateTime(2026, 11, 4), status: "Cancelled")),
          QuaiStatus.cancelled);
      expect(statusOf(_o("A", DateTime(2026, 11, 4), status: "ANNULÉ")),
          QuaiStatus.cancelled);
      expect(statusOf(_o("A", DateTime(2026, 11, 4))), isNull);
    });
    test("service kinds and week helpers", () {
      expect(
          serviceKindOf(
              _o("A", DateTime(2026, 11, 4), service: "Installation")),
          ServiceKind.install);
      expect(
          serviceKindOf(_o("A", DateTime(2026, 11, 4), service: "Livraison")),
          ServiceKind.delivery);
      expect(serviceKindOf(_o("A", DateTime(2026, 11, 4), service: "Pick-up")),
          ServiceKind.pickup);
      expect(mondayOf(DateTime(2026, 11, 4)), DateTime(2026, 11, 2));
      expect(mondayOf(DateTime(2026, 11, 8)), DateTime(2026, 11, 2));
      expect(daysFrom(DateTime(2026, 10, 30), 4).last, DateTime(2026, 11, 2));
      final sorted = sortedForDay(<Order>[
        _o("C", DateTime(2026, 11, 4), status: "cancelled"),
        _o("K", DateTime(2026, 11, 4), status: "confirmed")
      ]);
      expect(sorted.map((o) => o.soNum), <String>["K", "C"]);
      expect(
          effectiveSelectedDay(
              picked: DateTime(2026, 11, 9),
              weekStart: DateTime(2026, 11, 2),
              today: DateTime(2026, 11, 4)),
          DateTime(2026, 11, 4));
      expect(
          effectiveSelectedDay(
              picked: null,
              weekStart: DateTime(2026, 11, 9),
              today: DateTime(2026, 11, 4)),
          DateTime(2026, 11, 9));
    });
  });

  testWidgets(
      "StatusChip: filled dot = confirmed, hollow dot = provisional, crimson = cancelled",
      (t) async {
    await t.pumpWidget(_host(
      const Scaffold(
          body: Column(children: <Widget>[
        StatusChip(status: QuaiStatus.confirmed),
        StatusChip(status: QuaiStatus.tentative),
        StatusChip(status: QuaiStatus.cancelled),
      ])),
      const <Order>[],
    ));
    await _settle(t);
    expect(
        find.descendant(
            of: find.byKey(const Key("status-confirmed")),
            matching: find.byKey(const Key("dot-filled"))),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key("status-tentative")),
            matching: find.byKey(const Key("dot-hollow"))),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key("status-cancelled")),
            matching: find.byKey(const Key("dot-filled"))),
        findsOneWidget);
  });

  testWidgets(
      "phone (390): day strip + agenda for today, cards with service rails, no overflow",
      (t) async {
    _size(t, 390, 844);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 12);
    await t.pumpWidget(_host(const CalendarScreen(), <Order>[
      _o("SO1", today,
          status: "CONFIRMED", service: "Livraison", customer: "Un Client"),
      _o("SO2", today,
          status: "TENTATIVE", service: "Installation", customer: "Deux"),
      _o("SO3", today.add(const Duration(days: 1)), customer: "Demain"),
    ]));
    await _settle(t);
    expect(t.takeException(), isNull);
    expect(find.byKey(const Key("brand-header")), findsOneWidget);
    expect(find.byKey(const Key("nav-calendar")), findsOneWidget,
        reason: "bottom navigation on phone");
    expect(find.byKey(const Key("card-SO1")), findsOneWidget);
    expect(find.byKey(const Key("card-SO2")), findsOneWidget);
    expect(find.byKey(const Key("status-confirmed")), findsOneWidget);
    expect(find.byKey(const Key("status-tentative")), findsOneWidget);
    expect(find.byKey(const Key("dot-hollow")), findsOneWidget);
    // the rail of an installation is ink, a delivery is lake teal
    expect(t.widget<Container>(find.byKey(const Key("rail-SO2"))).color,
        QuaiColors.light.install);
    expect(t.widget<Container>(find.byKey(const Key("rail-SO1"))).color,
        QuaiColors.light.delivery);
    expect(find.byKey(Key("strip-${today.day}")), findsOneWidget);
  });

  for (final w in <double>[360, 390, 430]) {
    for (final n in <int>[0, 1, 3]) {
      testWidgets(
          "phone strip ($w, ${n} dots): selected pill and every day are centred in their column",
          (t) async {
        _size(t, w, 844);
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day, 12);
        await t.pumpWidget(_host(const CalendarScreen(), <Order>[
          for (var i = 0; i < n; i++)
            _o("SO$i", today, service: "Livraison", customer: "C$i"),
        ]));
        await _settle(t);
        expect(t.takeException(), isNull);
        final strips = find.byWidgetPredicate((wd) =>
            wd.key is ValueKey<String> &&
            RegExp(r"^strip-\d+$")
                .hasMatch((wd.key as ValueKey<String>).value));
        expect(strips, findsNWidgets(7));
        final sel = find.byKey(Key("strip-${today.day}"));
        final height = t.getSize(sel).height;
        final width = t.getSize(sel).width;
        for (var i = 0; i < 7; i++) {
          final cell = strips.at(i);
          expect(t.getSize(cell).height, height,
              reason: "same height, no jump");
          expect((t.getSize(cell).width - width).abs() < 0.01, isTrue,
              reason: "same width");
          final cx = t.getCenter(cell).dx;
          for (final txt in find
              .descendant(of: cell, matching: find.byType(Text))
              .evaluate()) {
            expect((t.getCenter(find.byWidget(txt.widget)).dx - cx).abs() < 0.6,
                isTrue,
                reason: "label/number centred in column $i at $w");
          }
          final rows = find.descendant(of: cell, matching: find.byType(Row));
          if (rows.evaluate().isNotEmpty) {
            expect((t.getCenter(rows.first).dx - cx).abs() < 0.6, isTrue,
                reason: "dots centred in column $i at $w");
          }
        }
        // the pill does not overlap its neighbours
        for (var i = 0; i < 6; i++) {
          expect(
              t.getTopRight(strips.at(i)).dx <=
                  t.getTopLeft(strips.at(i + 1)).dx + 0.01,
              isTrue);
        }
      });
    }
  }

  testWidgets("phone: tapping another day in the strip switches the agenda",
      (t) async {
    _size(t, 390, 844);
    final now = DateTime.now();
    final base = DateTime(now.year, now.month, now.day, 12);
    final monday = mondayOf(base);
    final other = DateTime(
        monday.year,
        monday.month,
        monday.day +
            (base.weekday == DateTime.sunday
                ? 0
                : (base.weekday == DateTime.monday ? 2 : 0)),
        12);
    await t.pumpWidget(_host(const CalendarScreen(), <Order>[
      _o("TODAY1", base, customer: "Auj"),
      _o("OTHER1", other, customer: "Autre"),
    ]));
    await _settle(t);
    await t.tap(find.byKey(Key("strip-${other.day}")));
    await _settle(t);
    expect(find.byKey(const Key("card-OTHER1")), findsOneWidget);
  });

  testWidgets("wide (1440): 7-column week grid with full cards and a top bar",
      (t) async {
    _size(t, 1440, 900);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 12);
    await t.pumpWidget(_host(const CalendarScreen(), <Order>[
      _o("W1", today,
          status: "CONFIRMED", customer: "Very Long Client Name Incorporated"),
      _o("W2", today, status: "CANCELLED", customer: "Annulé"),
    ]));
    await _settle(t);
    expect(t.takeException(), isNull);
    expect(find.byKey(const Key("nav-calendar")), findsNothing,
        reason: "no bottom nav on the web layout");
    expect(find.byKey(const Key("logout-button")), findsOneWidget);
    expect(find.byKey(const Key("card-W1")), findsOneWidget);
    expect(find.byKey(const Key("status-cancelled")), findsOneWidget);
    final w = t.getSize(find.byKey(const Key("card-W1"))).width;
    expect(w, greaterThan(150),
        reason: "cards are widened so names and status do not truncate");
  });

  testWidgets("week navigation moves the range", (t) async {
    _size(t, 390, 844);
    await t.pumpWidget(_host(const CalendarScreen(), <Order>[]));
    await _settle(t);
    final before = t.widget<Text>(find.byKey(const Key("week-range"))).data;
    await t.tap(find.byKey(const Key("week-next")));
    await _settle(t);
    expect(t.widget<Text>(find.byKey(const Key("week-range"))).data,
        isNot(before));
    await t.tap(find.byKey(const Key("week-today")));
    await _settle(t);
    expect(t.widget<Text>(find.byKey(const Key("week-range"))).data, before);
  });
}
