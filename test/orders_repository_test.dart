import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/middleware_source.dart";
import "package:quai_calendar/api/orders_api.dart";
import "package:quai_calendar/api/orders_repository.dart";
import "package:quai_calendar/data/carriers.dart";
import "package:quai_calendar/logic/calendar_views.dart";
import "package:quai_calendar/logic/middleware_events.dart";
import "package:quai_calendar/models/order.dart";

Order _order(String so, {required int event, required int truck, String date = "2026-11-03", String service = "Livraison"}) => Order(
      kind: OrderKind.order,
      soNum: so,
      soId: 123,
      date: date,
      customer: "Client",
      serviceType: service,
      serviceEventId: event,
      truckId: truck,
    );

Order _transfer(String to, {required int event, int truck = 3}) => Order(
      kind: OrderKind.transfer,
      soNum: to,
      soId: 900,
      date: "2026-11-03",
      customer: "A → B",
      serviceType: "Transfert / Transfer",
      serviceEventId: event,
      truckId: truck,
    );

/// Fake job service keyed by token. Records which tokens were used.
class _Api implements OrdersApi {
  _Api({this.ship = const <String, List<Order>>{}, this.transfers = const <String, List<Order>>{}, this.unauthorized = const <String>{}});
  final Map<String, List<Order>> ship;
  final Map<String, List<Order>> transfers;
  final Set<String> unauthorized;
  final List<String> shipCalls = <String>[];
  final List<String> transferCalls = <String>[];

  @override
  Future<List<Order>> shipOrders(String token, {String? carrierName}) async {
    shipCalls.add(token);
    if (unauthorized.contains(token)) throw const UnauthorizedException();
    return ship[token] ?? <Order>[];
  }

  @override
  Future<List<Order>> transferOrders(String token, {String? carrierName}) async {
    transferCalls.add(token);
    return transfers[token] ?? <Order>[];
  }
}

class _Mw implements MiddlewareSource {
  _Mw(this.list);
  final List<MiddlewareEvent> list;
  int calls = 0;
  @override
  bool get configured => true;
  @override
  Future<List<MiddlewareEvent>> events(String location, {required DateTime from, required DateTime to}) async {
    calls++;
    expect(location, "Ste-Agathe");
    return list;
  }
}

MiddlewareEvent _ev(String id, String title, {String date = "2026-11-03", String so = "1"}) =>
    MiddlewareEvent(id: id, title: title, salesOrderId: so, startDate: date);

void main() {
  final interql = carrierByDisplayName("InterQL");
  final logistique = carrierByDisplayName(kLogistique);

  group("InterQL — one login covers trucks 3 and 4", () {
    test("loads both trucks and keeps separate events on the SAME sales order", () async {
      final api = _Api(
        ship: <String, List<Order>>{
          "tok3": <Order>[_order("SO123", event: 1, truck: 3)],
          "tok4": <Order>[_order("SO123", event: 2, truck: 4)],
        },
      );
      final repo = OrdersRepository(api: api, middleware: const UnconfiguredMiddlewareSource());
      final load = await repo.load(
        carrier: interql,
        carrierName: "InterQL",
        primaryToken: "tok3",
        linkedTokens: <String, String>{"OPEN GOOSENECK": "tok4"},
      );
      expect(load.orders.map((o) => o.truckId).toList()..sort(), <int?>[3, 4]);
      expect(load.orders.map((o) => o.carrierName).toSet(), <String?>{"InterQL"});
      expect(load.orders.length, 2);
      expect(load.orders.every((o) => o.soNum == "SO123"), isTrue);
    });

    test("transfers are fetched for BOTH trucks and each TO remembers its owner's token", () async {
      final api = _Api(
        transfers: <String, List<Order>>{
          "tok3": <Order>[_transfer("TO1", event: 11)],
          "tok4": <Order>[_transfer("TO2", event: 12, truck: 4)],
        },
      );
      final repo = OrdersRepository(api: api, middleware: const UnconfiguredMiddlewareSource());
      final load = await repo.load(
        carrier: interql,
        carrierName: "InterQL",
        primaryToken: "tok3",
        linkedTokens: <String, String>{"OPEN GOOSENECK": "tok4"},
      );
      expect(load.toTokens, <String, String>{"TO1": "tok3", "TO2": "tok4"});
      expect(load.orders.where((o) => o.isTransfer).length, 2);
    });

    test("only ever uses the tokens it was handed (it cannot sign in by itself)", () async {
      final api = _Api();
      final repo = OrdersRepository(api: api, middleware: const UnconfiguredMiddlewareSource());
      await repo.load(carrier: interql, carrierName: "InterQL", primaryToken: "tok3", linkedTokens: <String, String>{"OPEN GOOSENECK": "tok4"});
      await repo.load(carrier: interql, carrierName: "InterQL", primaryToken: "tok3", linkedTokens: <String, String>{"OPEN GOOSENECK": "tok4"});
      expect({...api.shipCalls, ...api.transferCalls}, <String>{"tok3", "tok4"});
    });

    test("the same event returned twice is shown once", () async {
      final dup = _order("SO1", event: 7, truck: 4);
      final api = _Api(ship: <String, List<Order>>{"tok4": <Order>[dup, dup]});
      final repo = OrdersRepository(api: api, middleware: const UnconfiguredMiddlewareSource());
      final load = await repo.load(carrier: interql, carrierName: "InterQL", primaryToken: "tok3", linkedTokens: <String, String>{"OPEN GOOSENECK": "tok4"});
      expect(load.orders.length, 1);
    });

    test("a linked truck with no token is reported, and the other truck still loads", () async {
      final api = _Api(ship: <String, List<Order>>{"tok3": <Order>[_order("SO1", event: 1, truck: 3)]});
      final repo = OrdersRepository(api: api, middleware: const UnconfiguredMiddlewareSource());
      final load = await repo.load(carrier: interql, carrierName: "InterQL", primaryToken: "tok3");
      expect(load.orders.length, 1);
      expect(load.failedTrucks, <String>["OPEN GOOSENECK"]);
    });

    test("a rejected token is flagged unauthorized without blanking the other truck", () async {
      final api = _Api(
        ship: <String, List<Order>>{"tok3": <Order>[_order("SO1", event: 1, truck: 3)]},
        unauthorized: <String>{"tok4"},
      );
      final repo = OrdersRepository(api: api, middleware: const UnconfiguredMiddlewareSource());
      final load = await repo.load(carrier: interql, carrierName: "InterQL", primaryToken: "tok3", linkedTokens: <String, String>{"OPEN GOOSENECK": "tok4"});
      expect(load.unauthorized, isTrue);
      expect(load.failedTrucks, <String>["OPEN GOOSENECK"]);
      expect(load.orders.length, 1);
    });

    test("admin aggregation includes both trucks WITHOUT an InterQL login", () async {
      final api = _Api(
        ship: <String, List<Order>>{
          "t3": <Order>[_order("SO123", event: 1, truck: 3)],
          "t4": <Order>[_order("SO123", event: 2, truck: 4)],
        },
      );
      final repo = OrdersRepository(api: api, middleware: const UnconfiguredMiddlewareSource());
      final goosenecks = carrierAccounts(kCarriers.where((c) => c.group == "Gooseneck").toList());
      expect(goosenecks.map((a) => a.username).toList(), <String>["RIDEAU GOOSENECK", "OPEN GOOSENECK"]);
      final load = await repo.loadAggregate(
        accounts: goosenecks,
        tokensByUsername: <String, String>{"RIDEAU GOOSENECK": "t3", "OPEN GOOSENECK": "t4"},
      );
      expect(api.shipCalls.toSet(), <String>{"t3", "t4"});
      expect(load.failedTrucks, isEmpty);
      expect(load.orders.length, 2);
      expect(load.orders.map((o) => o.carrierName).toSet(), <String?>{"InterQL"});
    });
  });

  group("SADM - Logistique", () {
    final tokens = <String, String>{
      "SADM - Éric": "eric",
      "SADM - Jayson": "jayson",
      "SADM - Mathieu": "mathieu",
      "SADM - Quai2go": "quai2go",
      "SADM - Steve": "steve",
      "RIDEAU GOOSENECK": "tok3",
      "OPEN GOOSENECK": "tok4",
    };

    test("loads ONLY the two Gooseneck trucks, never the individual SADM trucks", () async {
      final api = _Api();
      final repo = OrdersRepository(api: api, middleware: _Mw(<MiddlewareEvent>[]));
      await repo.load(carrier: logistique, carrierName: kLogistique, primaryToken: "david", linkedTokens: tokens);
      expect(api.shipCalls.toSet(), <String>{"tok3", "tok4"});
      expect(api.shipCalls.contains("david"), isFalse);
    });

    test("does not call the slow ship-calendar for its own login", () async {
      final api = _Api();
      final repo = OrdersRepository(api: api, middleware: _Mw(<MiddlewareEvent>[]));
      await repo.load(carrier: logistique, carrierName: kLogistique, primaryToken: "david", linkedTokens: tokens);
      expect(api.shipCalls.contains("david"), isFalse);
      expect(api.transferCalls.contains("david"), isFalse);
    });

    test("pulls the Ste-Agathe middleware events as the source of pick-ups", () async {
      final mw = _Mw(<MiddlewareEvent>[
        _ev("1", "Chibougamau/SO20113/RGL envirotech/Ramassage"),
        _ev("2", "SADM - Jayson/SO20425/Showroom Mirabel/INSTALLATION"),
      ]);
      final repo = OrdersRepository(api: _Api(), middleware: mw);
      final load = await repo.load(carrier: logistique, carrierName: kLogistique, primaryToken: "david", linkedTokens: tokens);
      expect(mw.calls, 1);
      final byKind = <CalendarViewKind, int>{};
      for (final o in load.orders) {
        byKind[calendarView(o)] = (byKind[calendarView(o)] ?? 0) + 1;
      }
      expect(byKind[CalendarViewKind.pickups], 1);
      expect(byKind[CalendarViewKind.delivInst], 1);
    });

    test("a middleware event that duplicates a ship-calendar order (same SO + date) is dropped", () async {
      final api = _Api(ship: <String, List<Order>>{"tok3": <Order>[_order("SO9", event: 5, truck: 3, date: "2026-11-04")]});
      final mw = _Mw(<MiddlewareEvent>[
        _ev("90", "SADM - X/SO9/Cust/Livraison", date: "2026-11-04"),
        _ev("91", "SADM - X/SO9/Cust/Livraison", date: "2026-11-09"),
      ]);
      final load = await OrdersRepository(api: api, middleware: mw)
          .load(carrier: logistique, carrierName: kLogistique, primaryToken: "david", linkedTokens: tokens);
      final so9 = load.orders.where((o) => o.soNum == "SO9").toList();
      expect(so9.map((o) => o.date).toList()..sort(), <String>["2026-11-04", "2026-11-09"]);
    });

    test("TOs from the Gooseneck trucks land in the TOs tab", () async {
      final api = _Api(transfers: <String, List<Order>>{"tok4": <Order>[_transfer("TO7", event: 70, truck: 4)]});
      final load = await OrdersRepository(api: api, middleware: _Mw(<MiddlewareEvent>[]))
          .load(carrier: logistique, carrierName: kLogistique, primaryToken: "david", linkedTokens: tokens);
      expect(load.orders.map(calendarView).toList(), <CalendarViewKind>[CalendarViewKind.transfers]);
      expect(load.toTokens["TO7"], "tok4");
    });

    test("with no middleware proxy configured it SAYS pick-ups are unavailable", () async {
      final load = await OrdersRepository(api: _Api(), middleware: const UnconfiguredMiddlewareSource())
          .load(carrier: logistique, carrierName: kLogistique, primaryToken: "david", linkedTokens: tokens);
      expect(load.middlewareUnavailable, isTrue);
    });

    test("other carriers never touch the middleware", () async {
      final mw = _Mw(<MiddlewareEvent>[_ev("1", "SO1/x/y/Ramassage")]);
      final api = _Api(ship: <String, List<Order>>{"own": <Order>[_order("SO5", event: 1, truck: 64)]});
      final load = await OrdersRepository(api: api, middleware: mw)
          .load(carrier: carrierByDisplayName("Gat - Sam"), carrierName: "Gat - Sam", primaryToken: "own");
      expect(mw.calls, 0);
      expect(load.orders.length, 1);
      expect(load.middlewareUnavailable, isFalse);
    });
  });
}
