import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:intl/date_symbol_data_local.dart";
import "package:quai_calendar/api/backend_gateway.dart";
import "package:quai_calendar/api/order_change_service.dart";
import "package:quai_calendar/api/orders_repository.dart";
import "package:quai_calendar/api/prep_state_service.dart";
import "package:quai_calendar/api/session.dart";
import "package:quai_calendar/api/ticket_service.dart";
import "package:quai_calendar/data/carriers.dart";
import "package:quai_calendar/i18n/i18n.dart";
import "package:quai_calendar/l10n/key_map.dart";
import "package:quai_calendar/logic/calendar_views.dart";
import "package:quai_calendar/logic/contact_parser.dart";
import "package:quai_calendar/logic/prep_state.dart";
import "package:quai_calendar/models/order.dart";
import "package:quai_calendar/screens/calendar_screen.dart";
import "package:quai_calendar/screens/order_detail_screen.dart";
import "package:quai_calendar/screens/ticket_sheet.dart";
import "package:quai_calendar/state/order_change_providers.dart";
import "package:quai_calendar/state/prep_providers.dart";
import "package:quai_calendar/state/providers.dart";

Strings _strings() {
  final values = <String, String>{};
  kOriginalKeyToArb
      .forEach((dotted, arb) => values[arb] = dotted.split(".").last);
  return Strings.forTests(values);
}

String _today() => DateTime.now().toIso8601String().substring(0, 10);

class FakePrepTransport implements OrderChangeTransport {
  final List<String> calls = <String>[];
  final List<Object?> putBodies = <Object?>[];
  final List<Map<String, String>> getQueries = <Map<String, String>>[];
  final Map<String, Map<String, dynamic>> server =
      <String, Map<String, dynamic>>{};
  Object? failPut;
  Completer<void>? gatePut;
  bool isConfigured = true;

  void seed(String num, String date,
      {String by = "Québec - Logistique", String label = "Marc"}) {
    server["$num|$date"] = <String, dynamic>{
      "orderNum": num,
      "date": date,
      "prepared": true,
      "by": by,
      "label": label,
      "at": "2026-11-06T15:42:00.000Z",
    };
  }

  @override
  bool get configured => isConfigured;

  @override
  Future<Map<String, dynamic>> send(String method, String path,
      {Object? body, Map<String, String>? query}) async {
    calls.add("$method $path");
    if (method == "GET" && path == "/prep-state") {
      getQueries.add(query ?? <String, String>{});
      final from = query!["from"]!, to = query["to"]!;
      return <String, dynamic>{
        "states": <Map<String, dynamic>>[
          for (final e in server.values)
            if ((e["date"] as String).compareTo(from) >= 0 &&
                (e["date"] as String).compareTo(to) <= 0)
              e
        ],
      };
    }
    if (method == "PUT" && path.startsWith("/prep-state/")) {
      putBodies.add(body);
      if (gatePut != null) await gatePut!.future;
      if (failPut != null) throw failPut!;
      final b = body as Map<String, dynamic>;
      final num = Uri.decodeComponent(path.substring("/prep-state/".length));
      final key = "$num|${b["date"]}";
      if (b["prepared"] == true) {
        seed(num, b["date"] as String, by: "SADM - Logistique", label: "");
      } else {
        server.remove(key);
      }
      return <String, dynamic>{
        "orderNum": num,
        "date": b["date"],
        "prepared": b["prepared"],
        "by": "SADM - Logistique",
        "label": "",
        "at": "2026-11-06T15:42:00.000Z",
        "changed": true,
      };
    }
    if (path == "/orders/changed")
      return <String, dynamic>{"changed": <String, dynamic>{}};
    return <String, dynamic>{};
  }
}

Order _o(String num,
        {String? date,
        String? type = "Livraison",
        String? eventStatus,
        OrderKind kind = OrderKind.order,
        String? memo,
        int? soId,
        bool noTruck = false,
        String? customer}) =>
    Order(
      kind: kind,
      soNum: num,
      date: date ?? _today(),
      customer: customer ?? "Client $num",
      serviceType: type,
      eventStatus: eventStatus,
      memo: memo,
      soId: soId,
      truckName: noTruck ? null : "Camion 62",
      carrierName: noTruck ? "SADM - Logistique" : "SADM - David",
    );

final String _longMemo = List<String>.generate(
        30, (i) => "Consigne $i: porte arrière, appeler avant d'arriver.")
    .join(" ");

final List<Order> _orders = <Order>[
  _o("SOA", memo: _longMemo, soId: 11, customer: "Deroy Construction"),
  _o("SOB"),
  _o("SOCAN", eventStatus: "Cancelled"),
  _o("SOPICK", type: "Pick-up"),
];

MemorySessionStore _signedIn(String name, String role) {
  final store = MemorySessionStore();
  Session(store)
      .signIn(token: "t", name: name, role: role, sessionToken: "jwt");
  return store;
}

Widget _host(FakePrepTransport t,
        {List<Order>? orders,
        String role = kRoleLogistique,
        String name = "Québec - Logistique",
        List<Override> extra = const <Override>[]}) =>
    ProviderScope(
      overrides: <Override>[
        ordersProvider.overrideWith((ref) async => orders ?? _orders),
        ordersLoadProvider.overrideWith((ref) async => const OrdersLoad()),
        currentCarrierProvider.overrideWith((ref) => name),
        sessionStoreProvider.overrideWithValue(_signedIn(name, role)),
        orderChangeTransportProvider.overrideWithValue(t),
        orderContactProvider.overrideWith((ref, soNum) async =>
            const OrderContact(
                phone: "819 555-1234", address: "12 rue Principale, Gatineau")),
        ...extra,
      ],
      child: StringsScope(
          strings: _strings(),
          child: const MaterialApp(home: CalendarScreen())),
    );

void _size(WidgetTester tester, double w) {
  tester.view.physicalSize = Size(w, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder _inPill(String key, String text) =>
    find.descendant(of: find.byKey(Key(key)), matching: find.text(text));

void main() {
  setUpAll(initializeDateFormatting);

  group("logic", () {
    test(
        "key = order number + calendar day; the same order on two days is two keys",
        () {
      expect(prepKey(" so1 ", "2026-11-06"), "SO1|2026-11-06");
      expect(prepKeyOf(_o("SO1", date: "2026-11-06")), "SO1|2026-11-06");
      expect(
          prepKeyOf(_o("SO1", date: "2026-11-06T00:00:00")), "SO1|2026-11-06");
      expect(
          prepKeyOf(_o("SO1", date: "2026-11-07")) ==
              prepKeyOf(_o("SO1", date: "2026-11-06")),
          isFalse);
    });

    test("who may change it: logistics logins and the SuperUser only", () {
      expect(canPrepare(kRoleLogistique), isTrue);
      expect(canPrepare(kRoleSuperUser), isTrue);
      expect(canPrepare(kRoleCarrier), isFalse);
      expect(canPrepare(null), isFalse);
    });

    test(
        "only cancelled orders have no prepared state; deliveries, installs, pick-ups and transfers do",
        () {
      expect(needsPrep(_o("A")), isTrue);
      expect(needsPrep(_o("A", type: "Installation")), isTrue);
      expect(
          needsPrep(_o("TO1",
              kind: OrderKind.transfer, type: "Transfert / Transfer")),
          isTrue);
      expect(needsPrep(_o("A", type: "Pick-up")), isTrue);
      expect(needsPrep(_o("A", eventStatus: "Cancelled")), isFalse);
    });

    test("counter: counts every order except cancelled ones", () {
      final states = <String, PrepEntry>{
        prepKeyOf(_orders[0]): const PrepEntry(prepared: true),
        prepKeyOf(_orders[2]): const PrepEntry(prepared: true)
      };
      final c = prepCount(_orders, states);
      expect(c.total, 3,
          reason: "delivery, delivery, pick-up (cancelled not counted)");
      expect(c.done, 1);
      expect(c.fraction, closeTo(1 / 3, 1e-9));
      expect(c.complete, isFalse);
      expect(prepCount(<Order>[_orders[0]], states).complete, isTrue);
      expect(prepCount(const <Order>[], states).fraction, 0);
    });

    test(
        "stamp: who and time; the label wins over the login; another day adds the date",
        () {
      final at = DateTime(2026, 11, 6, 10, 42);
      expect(
          prepStamp(
              PrepEntry(
                  prepared: true,
                  by: "SADM - Logistique",
                  label: "Marc",
                  at: at),
              DateTime(2026, 11, 6, 15)),
          "Marc · 10:42");
      expect(
          prepStamp(PrepEntry(prepared: true, by: "SADM - Logistique", at: at),
              DateTime(2026, 11, 6, 15)),
          "SADM - Logistique · 10:42");
      expect(
          prepStamp(PrepEntry(prepared: true, label: "Marc", at: at),
              DateTime(2026, 11, 7, 8)),
          "Marc · 6/11 10:42");
      expect(
          prepStamp(const PrepEntry(prepared: true, label: "Marc"),
              DateTime(2026, 11, 7)),
          "Marc");
    });

    test(
        "server answer: only prepared rows become entries, keyed by order + date",
        () {
      final m = parsePrepStates(<String, dynamic>{
        "states": <Map<String, dynamic>>[
          <String, dynamic>{
            "orderNum": "so1",
            "date": "2026-11-06",
            "prepared": true,
            "by": "X",
            "label": "Marc",
            "at": "2026-11-06T15:42:00.000Z"
          },
          <String, dynamic>{
            "orderNum": "SO2",
            "date": "2026-11-06",
            "prepared": false
          },
          <String, dynamic>{"date": "2026-11-06", "prepared": true},
        ],
      });
      expect(m.keys.toList(), <String>["SO1|2026-11-06"]);
      expect(m["SO1|2026-11-06"]!.who, "Marc");
      expect(m["SO1|2026-11-06"]!.at, isNotNull);
      expect(parsePrepStates(<String, dynamic>{}), isEmpty);
    });
  });

  group("service", () {
    test("fetch asks for the window; set sends PUT with prepared + date",
        () async {
      final t = FakePrepTransport()..seed("SO1", "2026-11-06");
      final svc = PrepStateService(transport: t);
      final got = await svc.fetch("2026-11-02", "2026-11-08");
      expect(t.getQueries.single,
          <String, String>{"from": "2026-11-02", "to": "2026-11-08"});
      expect(got.keys, contains("SO1|2026-11-06"));
      final e = await svc.set("so 2/x", "2026-11-06", true);
      expect(t.calls.last, "PUT /prep-state/SO%202%2FX");
      expect(t.putBodies.last,
          <String, dynamic>{"prepared": true, "date": "2026-11-06"});
      expect(e.prepared, isTrue);
    });
  });

  group("controller", () {
    ProviderContainer container(FakePrepTransport t) {
      final c = ProviderContainer(overrides: <Override>[
        orderChangeTransportProvider.overrideWithValue(t),
        currentCarrierProvider.overrideWith((ref) => "SADM - Logistique"),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test("refresh replaces its own window and leaves other days alone",
        () async {
      final t = FakePrepTransport()..seed("SOA", "2026-11-06");
      final c = container(t);
      final ctrl = c.read(prepControllerProvider.notifier);
      await ctrl.refresh("2026-11-06", "2026-11-06");
      expect(c.read(prepControllerProvider).entries.keys,
          <String>["SOA|2026-11-06"]);
      t.seed("SOB", "2026-11-20");
      await ctrl.refresh("2026-11-20", "2026-11-20");
      expect(c.read(prepControllerProvider).entries.length, 2);
      t.server.remove("SOA|2026-11-06"); // a colleague undid it
      await ctrl.refresh("2026-11-06", "2026-11-06");
      expect(c.read(prepControllerProvider).entries.keys,
          <String>["SOB|2026-11-20"]);
    });

    test(
        "a tap flips at once; a poll during the save cannot undo it; the server answer wins",
        () async {
      final t = FakePrepTransport()..gatePut = Completer<void>();
      final c = container(t);
      final ctrl = c.read(prepControllerProvider.notifier);
      final order = _o("SOA", date: "2026-11-06");
      final saving =
          ctrl.setPrepared(order, true, now: DateTime(2026, 11, 6, 10, 42));
      expect(c.read(prepControllerProvider).isPrepared(order), isTrue,
          reason: "optimistic");
      await ctrl.refresh(
          "2026-11-06", "2026-11-06"); // server does not know it yet
      expect(c.read(prepControllerProvider).isPrepared(order), isTrue,
          reason: "in-flight key is protected");
      t.gatePut!.complete();
      await saving;
      expect(c.read(prepControllerProvider).of(order)!.by, "SADM - Logistique");
    });

    test("a failed save restores the old state and rethrows", () async {
      final t = FakePrepTransport()
        ..failPut = const BackendException(403, "role_not_allowed");
      final c = container(t);
      final ctrl = c.read(prepControllerProvider.notifier);
      final order = _o("SOA", date: "2026-11-06");
      await expectLater(ctrl.setPrepared(order, true, now: DateTime.now()),
          throwsA(isA<BackendException>()));
      expect(c.read(prepControllerProvider).isPrepared(order), isFalse);
      t.failPut = null;
      await ctrl.setPrepared(order, true, now: DateTime.now());
      t.failPut = const BackendException(500, "boom");
      await expectLater(ctrl.setPrepared(order, false, now: DateTime.now()),
          throwsA(isA<BackendException>()));
      expect(c.read(prepControllerProvider).isPrepared(order), isTrue,
          reason: "back to prepared");
    });

    test("nothing is called while the server is not configured", () async {
      final t = FakePrepTransport()..isConfigured = false;
      final c = container(t);
      await c
          .read(prepControllerProvider.notifier)
          .refresh("2026-11-06", "2026-11-06");
      expect(t.calls, isEmpty);
    });
  });

  group("calendar (phone)", () {
    testWidgets("counter, one-tap toggle, 6 s UNDO, green dot", (tester) async {
      _size(tester, 400);
      final t = FakePrepTransport();
      await tester.pumpWidget(_host(t));
      await _settle(tester);

      expect(find.byKey(const Key("prep-SOA")), findsOneWidget);
      expect(find.byKey(const Key("prep-SOB")), findsOneWidget);
      expect(find.byKey(const Key("prep-SOCAN")), findsNothing,
          reason: "cancelled");
      expect(find.byKey(const Key("prep-SOPICK")), findsOneWidget,
          reason: "pick-ups are prepared too");
      expect(_inPill("prep-SOA", "À préparer"), findsOneWidget);
      expect(find.text("0/3 préparées"), findsOneWidget);
      expect(find.byKey(const Key("prep-progress")), findsOneWidget);
      expect(t.getQueries, isNotEmpty, reason: "loaded on open");

      await tester.tap(find.byKey(const Key("prep-SOA")));
      await tester.pump();
      expect(_inPill("prep-SOA", "Préparé"), findsOneWidget,
          reason: "flips at once");
      expect(find.byKey(const Key("prep-stamp")), findsOneWidget);
      expect(find.text("1/3 préparées"), findsOneWidget);
      expect(find.byKey(const Key("strip-dot-prepared-SOA")), findsWidgets);
      await tester.pump(const Duration(milliseconds: 750));
      expect(find.byKey(const Key("prep-snackbar")), findsOneWidget);
      expect(find.text("ANNULER"), findsOneWidget);
      expect(t.putBodies.single,
          <String, dynamic>{"prepared": true, "date": _today()});
      expect(find.byType(AlertDialog), findsNothing,
          reason: "no confirmation dialog");

      await tester.tap(find.text("ANNULER"));
      await tester.pump();
      await _settle(tester);
      expect(_inPill("prep-SOA", "À préparer"), findsOneWidget);
      expect(find.text("0/3 préparées"), findsOneWidget);
      expect(t.putBodies.last,
          <String, dynamic>{"prepared": false, "date": _today()});
      expect(t.server, isEmpty);

      await tester.pump(const Duration(seconds: 7));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("the snackbar disappears after 6 seconds", (tester) async {
      _size(tester, 400);
      await tester.pumpWidget(_host(FakePrepTransport()));
      await _settle(tester);
      await tester.tap(find.byKey(const Key("prep-SOB")));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 750));
      expect(find.byKey(const Key("prep-snackbar")), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 750));
      expect(find.byKey(const Key("prep-snackbar")), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("a refused save puts the button back and says why",
        (tester) async {
      _size(tester, 400);
      final t = FakePrepTransport()
        ..failPut = const BackendException(403, "role_not_allowed");
      await tester.pumpWidget(_host(t));
      await _settle(tester);
      await tester.tap(find.byKey(const Key("prep-SOA")));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 750));
      expect(_inPill("prep-SOA", "À préparer"), findsOneWidget);
      expect(find.byKey(const Key("prep-error")), findsOneWidget);
      expect(find.text("Seule la logistique peut changer cet état."),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("a colleague's change shows up within 30 s without any tap",
        (tester) async {
      _size(tester, 400);
      final t = FakePrepTransport();
      await tester.pumpWidget(_host(t));
      await _settle(tester);
      expect(find.text("0/3 préparées"), findsOneWidget);
      final first = t.getQueries.length;
      t.seed("SOB", _today());
      await tester.pump(const Duration(seconds: 31));
      await _settle(tester);
      expect(t.getQueries.length, greaterThan(first));
      expect(find.text("1/3 préparées"), findsOneWidget);
      expect(_inPill("prep-SOB", "Préparé"), findsOneWidget);
      expect(find.textContaining("Marc"), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("not configured: no button, no counter, no polling",
        (tester) async {
      _size(tester, 400);
      final t = FakePrepTransport()..isConfigured = false;
      await tester.pumpWidget(_host(t));
      await _settle(tester);
      expect(find.byKey(const Key("prep-SOA")), findsNothing);
      expect(find.byKey(const Key("prep-counter")), findsNothing);
      await tester.pump(const Duration(seconds: 61));
      expect(t.calls.where((c) => c.contains("/prep-state")), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        "a carrier sees the state read-only, and only once it is prepared",
        (tester) async {
      _size(tester, 400);
      final t = FakePrepTransport()..seed("SOB", _today());
      await tester.pumpWidget(_host(t, role: kRoleCarrier, name: "Gat - Sam"));
      await _settle(tester);
      expect(find.byKey(const Key("prep-SOA")), findsNothing);
      expect(find.byKey(const Key("prep-ro-SOA")), findsNothing,
          reason: "nothing to say about an unprepared order");
      expect(find.byKey(const Key("prep-SOB")), findsNothing,
          reason: "no tappable button");
      expect(_inPill("prep-ro-SOB", "Préparé"), findsOneWidget);
      final pill = find.descendant(
          of: find.byKey(const Key("prep-ro-SOB")),
          matching: find.byType(InkWell));
      expect(tester.widget<InkWell>(pill).onTap, isNull,
          reason: "read-only: nothing to tap");
      expect(t.putBodies, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group("calendar (wide) and order detail", () {
    Future<void> openDetail(WidgetTester tester, String num) async {
      final card = find.byKey(Key("card-$num"));
      await tester.tapAt(tester.getTopLeft(card) + const Offset(40, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets(
        "dense cards carry the button; tapping the card opens the detail for logistics",
        (tester) async {
      _size(tester, 1440);
      final t = FakePrepTransport();
      await tester.pumpWidget(_host(t));
      await _settle(tester);
      expect(find.byKey(const Key("prep-SOA")), findsOneWidget);
      await openDetail(tester, "SOA");
      expect(find.byType(OrderDetailScreen), findsOneWidget);
      expect(find.byType(TicketSheet), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        "detail: client, call and maps, tiles, full memo, sticky prepared button, no money",
        (tester) async {
      _size(tester, 1440);
      final t = FakePrepTransport();
      final launched = <Uri>[];
      await tester.pumpWidget(_host(t, extra: <Override>[
        urlLauncherProvider.overrideWithValue((uri) async => launched.add(uri))
      ]));
      await _settle(tester);
      await openDetail(tester, "SOA");

      expect(tester.widget<Text>(find.byKey(const Key("detail-customer"))).data,
          "Deroy Construction");
      expect(find.byKey(const Key("detail-phone")), findsOneWidget);
      expect(find.byKey(const Key("detail-address")), findsOneWidget);
      for (final k in <String>["date", "method", "truck", "unit"]) {
        expect(find.byKey(Key("detail-tile-$k")), findsOneWidget, reason: k);
      }
      expect(
          find.descendant(
              of: find.byKey(const Key("detail-tile-truck")),
              matching: find.text("Camion 62")),
          findsOneWidget);
      final memo =
          tester.widget<Text>(find.byKey(const Key("detail-memo-text")));
      expect(memo.data, _longMemo.trim());
      expect(memo.maxLines, isNull, reason: "the memo is never truncated");
      expect(memo.overflow, isNull);
      for (final word in <String>["Dépôt", "Solde", "Deposit", "Balance"]) {
        expect(find.textContaining(word), findsNothing,
            reason: "no money for logistics: $word");
      }

      await tester.tap(find.byKey(const Key("detail-call")));
      await tester.tap(find.byKey(const Key("detail-maps")));
      expect(launched.first.toString(), "tel:8195551234");
      expect(launched.last.toString(),
          startsWith("https://www.google.com/maps/dir/?api=1&destination="));
      expect(launched.last.toString(),
          contains(Uri.encodeComponent("12 rue Principale, Gatineau")));

      final bar = find.byKey(const Key("detail-prep-bar"));
      expect(bar, findsOneWidget);
      expect(
          find.descendant(of: bar, matching: find.byKey(const Key("prep-SOA"))),
          findsOneWidget);
      await tester.tap(find.descendant(
          of: bar, matching: find.byKey(const Key("prep-SOA"))));
      await _settle(tester);
      expect(find.descendant(of: bar, matching: find.text("Préparé")),
          findsOneWidget);
      expect(t.server.keys, contains("SOA|${_today()}"));
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("detail: 'Bon de vente' opens the picking ticket",
        (tester) async {
      _size(tester, 1440);
      final stuck = TicketService(
        fetch: (String? t, String n,
                {void Function(double? fraction)? onDownload}) =>
            Completer<TicketHttpResult>().future,
        tokens: _NoTokens(),
      );
      await tester.pumpWidget(_host(FakePrepTransport(),
          extra: <Override>[ticketServiceProvider.overrideWithValue(stuck)]));
      await _settle(tester);
      await openDetail(tester, "SOB");
      expect(find.byKey(const Key("detail-memo")), findsNothing,
          reason: "no memo, no memo block");
      await tester.ensureVisible(find.byKey(const Key("detail-ticket")));
      await tester.tap(find.byKey(const Key("detail-ticket")));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TicketSheet), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key("ticket-title"))).data,
          "SOB");
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("a carrier's card still opens the picking ticket (unchanged)",
        (tester) async {
      _size(tester, 1440);
      final stuck = TicketService(
        fetch: (String? t, String n,
                {void Function(double? fraction)? onDownload}) =>
            Completer<TicketHttpResult>().future,
        tokens: _NoTokens(),
      );
      await tester.pumpWidget(_host(FakePrepTransport(),
          role: kRoleCarrier,
          name: "Gat - Sam",
          extra: <Override>[ticketServiceProvider.overrideWithValue(stuck)]));
      await _settle(tester);
      await openDetail(tester, "SOA");
      expect(find.byType(TicketSheet), findsOneWidget);
      expect(find.byType(OrderDetailScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group(
      "every job type shows the prepared button (logistique + superuser; only cancelled orders do not)",
      () {
    final all = <Order>[
      _o("SODEL", type: "Livraison", eventStatus: "Confirmed"),
      _o("SOINS", type: "Installation", eventStatus: "Confirmed"),
      _o("SOPICK1", type: "Pick-up", eventStatus: "Tentative", noTruck: true),
      _o("SOPICK2", type: "Pick-up", eventStatus: "Confirmed"),
      _o("TO9",
          kind: OrderKind.transfer,
          type: "Transfert / Transfer",
          eventStatus: "Confirmed"),
      _o("SOCAN2", type: "Pick-up", eventStatus: "Cancelled"),
    ];
    final tabs = <CalendarViewKind, List<String>>{
      CalendarViewKind.delivInst: <String>["SODEL", "SOINS"],
      CalendarViewKind.pickups: <String>["SOPICK1", "SOPICK2"],
      CalendarViewKind.transfers: <String>["TO9"],
    };

    for (final role in <String>[kRoleLogistique, kRoleSuperUser]) {
      for (final width in <double>[400, 1440]) {
        testWidgets("cards on every tab: role $role, width $width",
            (tester) async {
          for (final e in tabs.entries) {
            _size(tester, width);
            final t = FakePrepTransport();
            await tester.pumpWidget(_host(t,
                orders: all,
                role: role,
                name: kLogistique,
                extra: <Override>[
                  logistiqueViewProvider.overrideWith((ref) => e.key),
                ]));
            await _settle(tester);
            for (final num in e.value) {
              expect(find.byKey(Key("prep-$num")), findsOneWidget,
                  reason: "$num on ${e.key.name}");
            }
            expect(find.byKey(const Key("prep-SOCAN2")), findsNothing,
                reason: "cancelled");
            expect(
                width > 500 ||
                    find
                        .textContaining("0/${e.value.length} préparée")
                        .evaluate()
                        .isNotEmpty,
                isTrue,
                reason: "counter ${e.key.name}");
            await tester.pumpWidget(const SizedBox());
          }
        });
      }
    }

    for (final role in <String>[kRoleLogistique, kRoleSuperUser]) {
      for (final num in <String>["SODEL", "SOPICK1", "SOPICK2", "TO9"]) {
        testWidgets(
            "detail sticky bar: $num as $role (provisional / no truck included)",
            (tester) async {
          _size(tester, 400);
          final t = FakePrepTransport();
          final view = num == "TO9"
              ? CalendarViewKind.transfers
              : num.startsWith("SOPICK")
                  ? CalendarViewKind.pickups
                  : CalendarViewKind.delivInst;
          await tester.pumpWidget(_host(t,
              orders: all,
              role: role,
              name: kLogistique,
              extra: <Override>[
                logistiqueViewProvider.overrideWith((ref) => view),
              ]));
          await _settle(tester);
          final card = find.byKey(Key("card-$num"));
          await tester.tapAt(tester.getTopLeft(card) + const Offset(40, 10));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(find.byType(OrderDetailScreen), findsOneWidget);
          final bar = find.byKey(const Key("detail-prep-bar"));
          expect(bar, findsOneWidget, reason: "sticky bar for $num");
          expect(
              find.descendant(of: bar, matching: find.byKey(Key("prep-$num"))),
              findsOneWidget);
          await tester.tap(
              find.descendant(of: bar, matching: find.byKey(Key("prep-$num"))));
          await _settle(tester);
          expect(t.server.keys, contains("$num|${_today()}"));
          await tester.pump(const Duration(seconds: 7));
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
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
