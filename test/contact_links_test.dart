import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/i18n/i18n.dart";
import "package:quai_calendar/l10n/key_map.dart";
import "package:quai_calendar/logic/contact_parser.dart";
import "package:quai_calendar/state/providers.dart";
import "package:quai_calendar/widgets/contact_links.dart";

Strings _strings() {
  final values = <String, String>{};
  kOriginalKeyToArb
      .forEach((dotted, arb) => values[arb] = dotted.split(".").last);
  return Strings.forTests(values);
}

Widget _host(
        Future<OrderContact?> Function(String so) load, List<Uri> launched) =>
    ProviderScope(
      overrides: <Override>[
        orderContactProvider.overrideWith((ref, so) => load(so)),
        urlLauncherProvider.overrideWithValue((uri) async => launched.add(uri)),
      ],
      child: StringsScope(
        strings: _strings(),
        child:
            const MaterialApp(home: Scaffold(body: ContactLinks(soNum: "SO1"))),
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets("shows Call and Directions when both are known", (tester) async {
    await tester.pumpWidget(_host(
        (so) async => const OrderContact(
            phone: "819-555-0142", address: "1 rue A, Mirabel"),
        <Uri>[]));
    await _settle(tester);
    expect(find.byKey(const Key("call-SO1")), findsOneWidget);
    expect(find.byKey(const Key("maps-SO1")), findsOneWidget);
    expect(find.text("819-555-0142"), findsOneWidget);
    expect(find.text("Itinéraire"), findsOneWidget);
  });

  testWidgets("Call dials the number with a clean tel: link", (tester) async {
    final launched = <Uri>[];
    await tester.pumpWidget(_host(
        (so) async => const OrderContact(phone: "(819) 555-0142"), launched));
    await _settle(tester);
    await tester.tap(find.byKey(const Key("call-SO1")));
    await tester.pump();
    expect(launched.single.toString(), "tel:8195550142");
  });

  testWidgets("Directions opens Google Maps with the encoded address",
      (tester) async {
    final launched = <Uri>[];
    await tester.pumpWidget(_host(
        (so) async => const OrderContact(address: "1 rue A, Mirabel"),
        launched));
    await _settle(tester);
    await tester.tap(find.byKey(const Key("maps-SO1")));
    await tester.pump();
    expect(launched.single.toString(),
        startsWith("https://www.google.com/maps/dir/?api=1&destination="));
    expect(launched.single.toString(), contains("1%20rue%20A"));
  });

  testWidgets(
      "a phone with no address shows only Call (no dead Directions button)",
      (tester) async {
    await tester.pumpWidget(_host(
        (so) async => const OrderContact(phone: "819-555-0142"), <Uri>[]));
    await _settle(tester);
    expect(find.byKey(const Key("call-SO1")), findsOneWidget);
    expect(find.byKey(const Key("maps-SO1")), findsNothing);
  });

  testWidgets("an unknown contact renders nothing at all", (tester) async {
    await tester.pumpWidget(_host((so) async => null, <Uri>[]));
    await _settle(tester);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets("a lookup error renders nothing instead of an error box",
      (tester) async {
    await tester
        .pumpWidget(_host((so) async => throw StateError("boom"), <Uri>[]));
    await _settle(tester);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets("a small spinner shows while the contact is being read",
      (tester) async {
    final gate = Completer<OrderContact?>();
    await tester.pumpWidget(_host((so) => gate.future, <Uri>[]));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    gate.complete(const OrderContact(phone: "1"));
    await _settle(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const Key("call-SO1")), findsOneWidget);
  });
}
