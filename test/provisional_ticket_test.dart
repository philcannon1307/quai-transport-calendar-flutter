import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/sales_order_service.dart";
import "package:quai_calendar/api/ticket_service.dart";
import "package:quai_calendar/i18n/i18n.dart";
import "package:quai_calendar/l10n/key_map.dart";
import "package:quai_calendar/models/order.dart";
import "package:quai_calendar/screens/ticket_sheet.dart";
import "package:quai_calendar/state/providers.dart";
import "package:quai_calendar/widgets/provisional_ticket_view.dart";

class _Tokens implements TicketTokens {
  @override
  String? primaryToken() => "own";
  @override
  String? transferToken(String toNum) => null;
  @override
  String? carrierName() => "SADM - Logistique";
  @override
  List<String> sadmTruckTokens() => <String>[];
}

class _FakeSalesOrders implements SalesOrderService {
  _FakeSalesOrders(this.answer);
  final SalesOrderDetails? answer;
  final List<int> asked = <int>[];
  @override
  String get url => "x";
  @override
  String? Function() get token => () => "t";
  @override
  Future<SalesOrderDetails?> fetch(int salesOrderId) async {
    asked.add(salesOrderId);
    return answer;
  }
}

Strings _strings() {
  final values = <String, String>{};
  kOriginalKeyToArb.forEach((dotted, arb) => values[arb] = dotted.split(".").last);
  return Strings.forTests(values);
}

const _json = <String, dynamic>{
  "provisional": true,
  "salesOrderId": "268333",
  "soNum": "SO20448",
  "customer": "17208 Dominic Deroy",
  "status": "Pending Fulfillment",
  "shipDate": "2026-11-04",
  "address": "12 rue X",
  "phone": "+15145550000",
  "memo": "Appeler avant",
  "items": null,
  "itemsAvailable": false,
};

Widget _host(SalesOrderService? so, {int? soId = 268333}) => ProviderScope(
      overrides: <Override>[
        ticketServiceProvider.overrideWithValue(TicketService(
          fetch: (String? token, String ticketNum, {void Function(double? fraction)? onDownload}) async => const TicketHttpResult(404),
          tokens: _Tokens(),
          retryDelay: Duration.zero,
        )),
        salesOrderServiceProvider.overrideWithValue(so),
        ordersProvider.overrideWith((ref) async => <Order>[
              Order(kind: OrderKind.order, soNum: "SO20448", soId: soId, date: "2026-11-04"),
            ]),
      ],
      child: StringsScope(strings: _strings(), child: const MaterialApp(home: TicketSheet(orderNum: "SO20448"))),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  test("SalesOrderDetails: items null until the middleware serves them", () {
    final d = SalesOrderDetails.fromJson(_json);
    expect(d.soNum, "SO20448");
    expect(d.itemsAvailable, isFalse);
    final withItems = SalesOrderDetails.fromJson(<String, dynamic>{
      ..._json,
      "items": <dynamic>[
        <String, dynamic>{"name": "Quai 8x20", "sku": "Q-820", "quantity": 3, "unit": "ea", "memo": ""},
      ],
    });
    expect(withItems.itemsAvailable, isTrue);
    expect(withItems.items!.single.quantity, 3);
  });

  test("salesOrderUrlFor derives the route from the Pick-ups proxy URL", () {
    expect(salesOrderUrlFor("https://h.example/middleware/events"), "https://h.example/middleware/sales-order");
    expect(salesOrderUrlFor("https://h.example/"), "https://h.example/middleware/sales-order");
    expect(salesOrderUrlFor(""), "");
  });

  testWidgets("view: provisional banner + 'Items not available yet' when no items", (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ProvisionalTicketView(details: SalesOrderDetails.fromJson(_json)))));
    expect(find.byKey(const Key("provisional-banner")), findsOneWidget);
    expect(find.textContaining("PROVISOIRE"), findsOneWidget);
    expect(find.byKey(const Key("provisional-items-missing")), findsOneWidget);
    expect(find.textContaining("Dominic Deroy"), findsOneWidget);
    expect(find.textContaining("Appeler avant"), findsOneWidget);
  });

  testWidgets("view: item lines appear as soon as the server returns them", (tester) async {
    final d = SalesOrderDetails.fromJson(<String, dynamic>{
      ..._json,
      "items": <dynamic>[
        <String, dynamic>{"name": "Quai 8x20", "sku": "Q-820", "quantity": 3, "unit": "ea", "memo": ""},
      ],
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ProvisionalTicketView(details: d))));
    expect(find.byKey(const Key("provisional-items-missing")), findsNothing);
    expect(find.textContaining("Quai 8x20"), findsOneWidget);
  });

  testWidgets("ticket 404 for Logistique/SuperUser -> provisional list from the sales order id", (tester) async {
    final fake = _FakeSalesOrders(SalesOrderDetails.fromJson(_json));
    await tester.pumpWidget(_host(fake));
    await _settle(tester);
    expect(fake.asked, <int>[268333]);
    expect(find.byKey(const Key("provisional-ticket")), findsOneWidget);
    expect(find.byKey(const Key("ticket-error")), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("carriers (no service) keep the normal error; no provisional list", (tester) async {
    await tester.pumpWidget(_host(null));
    await _settle(tester);
    expect(find.byKey(const Key("provisional-ticket")), findsNothing);
    expect(find.byKey(const Key("ticket-error")), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("no sales order id or server failure -> normal error", (tester) async {
    await tester.pumpWidget(_host(_FakeSalesOrders(null)));
    await _settle(tester);
    expect(find.byKey(const Key("ticket-error")), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_host(_FakeSalesOrders(SalesOrderDetails.fromJson(_json)), soId: null));
    await _settle(tester);
    expect(find.byKey(const Key("ticket-error")), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
