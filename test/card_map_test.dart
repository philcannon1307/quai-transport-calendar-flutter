import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/logic/contact_parser.dart";
import "package:quai_calendar/models/order.dart";
import "package:quai_calendar/state/providers.dart";
import "package:quai_calendar/widgets/order_card.dart";

Order _o() => Order(
    kind: OrderKind.order,
    soNum: "SO20484",
    date: "2026-11-05",
    customer: "Richard Lévesque");

Widget _host(OrderContact? c) => ProviderScope(
      overrides: <Override>[
        orderContactProvider.overrideWith((ref, so) async => c),
      ],
      child: MaterialApp(home: Scaffold(body: OrderCardMap(order: _o()))),
    );

void main() {
  testWidgets("card map: 150px iframe with the delivery address as query", (tester) async {
    await tester.pumpWidget(_host(const OrderContact(address: "123 rue Principale, Saint-Donat QC")));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key("card-map-SO20484")), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key("map-frame"))).height, 150);
    final url = tester.widget<Text>(find.byKey(const Key("map-frame-url"))).data!;
    expect(url, contains("maps.google.com/maps"));
    expect(url, contains(Uri.encodeComponent("123 rue Principale, Saint-Donat QC")));
    expect(url, contains("output=embed"));
  });

  testWidgets("card map: no usable address draws nothing (no blank gap)", (tester) async {
    await tester.pumpWidget(_host(const OrderContact(address: "12")));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key("card-map-SO20484")), findsNothing);
    expect(tester.getSize(find.byType(OrderCardMap)).height, 0);
  });
}
