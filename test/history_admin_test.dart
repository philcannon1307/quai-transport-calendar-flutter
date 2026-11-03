import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/history_service.dart";
import "package:quai_calendar/data/carriers.dart";
import "package:quai_calendar/logic/admin_filters.dart";
import "package:quai_calendar/logic/delivery_history.dart";
import "package:quai_calendar/models/order.dart";

import "fake_backend.dart";

Order _o(String so, {String date = "2026-11-02", String? carrier, int? loc, String? locName, int? event}) => Order(
      kind: OrderKind.order,
      soNum: so,
      soId: 1,
      date: date,
      customer: "C",
      shipDate: date,
      carrierName: carrier,
      shippingLocationId: loc,
      shippingLocationName: locName,
      serviceEventId: event,
    );

void main() {
  group("history rows", () {
    test("two linked trucks sharing one sales order produce ONE row (else the whole upsert fails in Postgres)", () {
      final rows = historyRows(<Order>[
        _o("SO1", event: 1, carrier: "InterQL"),
        _o("SO1", event: 2, carrier: "InterQL"),
        _o("SO2", carrier: "InterQL"),
      ]);
      expect(rows.map((r) => r["so_num"]).toList(), <String>["SO1", "SO2"]);
    });

    test("orders without a number are skipped", () {
      expect(historyRows(<Order>[_o("")]), isEmpty);
    });

    test("a row round-trips to an Order", () {
      final row = historyRow(_o("TO55", carrier: "Gooseneck", loc: 7, locName: "Ste-Agathe"));
      final back = orderFromHistoryRow(row);
      expect(back.soNum, "TO55");
      expect(back.isTransfer, isTrue);
      expect(back.shippingLocationId, 7);
      expect(back.carrierName, "Gooseneck");
    });
  });

  group("window", () {
    test("N days back, today excluded, local dates", () {
      final w = historyWindow(7, DateTime(2026, 11, 3, 23, 30));
      expect(w.from, "2026-10-27");
      expect(w.to, "2026-11-03");
    });
    test("year crossing", () {
      expect(historyWindow(30, DateTime(2027, 1, 5)).from, "2026-12-06");
    });
  });

  group("merge", () {
    test("live wins over history for the same sales order; past-only come first", () {
      final merged = mergeLiveAndPast(<Order>[_o("SO1", date: "2026-11-05")], <Order>[_o("SO1", date: "2026-11-01"), _o("SO0", date: "2026-11-01")]);
      expect(merged.map((o) => o.soNum).toList(), <String>["SO0", "SO1"]);
      expect(merged.last.date, "2026-11-05");
    });
    test("no history leaves the live list untouched", () {
      final live = <Order>[_o("SO1")];
      expect(identical(mergeLiveAndPast(live, <Order>[]), live), isTrue);
    });
  });

  group("service", () {
    test("snapshot writes one de-duplicated batch", () async {
      final b = FakeBackend();
      final ok = await HistoryService(gateway: b).snapshot(<Order>[_o("SO1"), _o("SO1", event: 2)]);
      expect(ok, isTrue);
      expect(b.historyUpserts.single, hasLength(1));
    });
    test("snapshot of nothing, or unconfigured, writes nothing and never throws", () async {
      final b = FakeBackend();
      expect(await HistoryService(gateway: b).snapshot(<Order>[]), isFalse);
      expect(await HistoryService(gateway: FakeBackend(isConfigured: false)).snapshot(<Order>[_o("SO1")]), isFalse);
      expect(b.historyUpserts, isEmpty);
    });
    test("past() asks for the right window and carrier names", () async {
      final b = FakeBackend()..historyToReturn = <Map<String, dynamic>>[historyRow(_o("SO9"))];
      final out = await HistoryService(gateway: b, clock: () => DateTime(2026, 11, 3)).past(days: 7, carrierNames: <String>["InterQL"]);
      expect(out.single.soNum, "SO9");
      expect(b.historyQueries.single, <String, String>{"from": "2026-10-27", "to": "2026-11-03", "names": "InterQL"});
    });
    test("past(0) is live only: no query", () async {
      final b = FakeBackend();
      expect(await HistoryService(gateway: b).past(days: 0), isEmpty);
      expect(b.historyQueries, isEmpty);
    });
    test("carrier names include the display name and every linked truck", () {
      final names = historyCarrierNames(carrierByDisplayName("InterQL"), "InterQL");
      expect(names, contains("InterQL"));
      expect(names.length, greaterThan(1));
    });
  });

  group("admin filters", () {
    final orders = <Order>[
      _o("A", carrier: "SADM - David", loc: 1, locName: "Ste-Agathe"),
      _o("B", carrier: "SADM - Éric", loc: 1, locName: "Ste-Agathe"),
      _o("C", carrier: "InterQL", loc: 2, locName: "Gatineau"),
      _o("D", carrier: "Inconnu", loc: 2, locName: "Gatineau"),
      _o("E", carrier: "InterQL"),
    ];

    test("groups are counted from the roster; unknown carriers belong to none", () {
      final c = groupCounts(orders);
      expect(c[carrierByDisplayName("SADM - David")!.group], 2);
      expect(c.values.fold<int>(0, (a, b) => a + b), 4, reason: "Inconnu is not counted");
    });

    test("filtering by group and by location", () {
      final g = carrierByDisplayName("SADM - David")!.group;
      expect(filterByGroup(orders, g).map((o) => o.soNum).toList(), <String>["A", "B"]);
      expect(filterByGroup(orders, null), hasLength(5));
      expect(filterByLocation(orders, 2).map((o) => o.soNum).toList(), <String>["C", "D"]);
      expect(filterByLocation(filterByGroup(orders, g), 2), isEmpty);
    });

    test("locations come from the orders and orders without one are not counted", () {
      expect(locationsOf(orders).map((l) => l.name).toList(), <String>["Ste-Agathe", "Gatineau"]);
      expect(locationCounts(orders), <int, int>{1: 2, 2: 2});
    });

    test("pills: only those with orders (or selected), busiest first", () {
      final shown = visibleSorted<String>(<String>["x", "y", "z"], (k) => <String, int>{"x": 1, "y": 3, "z": 0}[k]!, (k) => k == "z");
      expect(shown, <String>["y", "x", "z"]);
    });
  });
}
