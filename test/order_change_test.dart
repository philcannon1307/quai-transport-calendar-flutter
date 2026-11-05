import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/backend_gateway.dart";
import "package:quai_calendar/api/order_change_service.dart";
import "package:quai_calendar/api/sales_order_service.dart";
import "package:quai_calendar/api/ticket_service.dart";
import "package:quai_calendar/i18n/i18n.dart";
import "package:quai_calendar/l10n/key_map.dart";
import "package:quai_calendar/logic/order_change.dart";
import "package:quai_calendar/models/order.dart";
import "package:quai_calendar/pdf/pdf_ports.dart";
import "package:quai_calendar/screens/ticket_sheet.dart";
import "package:quai_calendar/state/order_change_providers.dart";
import "package:quai_calendar/state/prep_providers.dart";
import "package:quai_calendar/state/providers.dart";
import "package:quai_calendar/widgets/order_change.dart";

class Call {
  Call(this.method, this.path, this.body, this.query);
  final String method;
  final String path;
  final Object? body;
  final Map<String, String>? query;
}

class FakeTransport implements OrderChangeTransport {
  final List<Call> calls = <Call>[];
  Object? failWith;
  Map<String, dynamic> previewJson = <String, dynamic>{
    "recipients": <Map<String, dynamic>>[
      <String, dynamic>{"email": "lindsay@groupeql.com", "roles": <String>["creator"], "division": "lindsay"},
      <String, dynamic>{"email": "sadm@groupeql.com", "roles": <String>["carrier", "dispatcher"]},
    ],
    "deliveredTo": <String>["communication@groupeql.com"],
    "testMode": true,
    "unresolved": <String>[],
  };
  Map<String, dynamic> maskedPreview = <String, dynamic>{
    "recipients": <Map<String, dynamic>>[
      <String, dynamic>{"roles": <String>["creator"], "division": "lindsay"},
      <String, dynamic>{"roles": <String>["dispatcher"]},
    ],
    "deliveredTo": <String>[],
    "testMode": true,
    "unresolved": <String>[],
  };
  Map<String, dynamic> submitJson = <String, dynamic>{"changeId": "c1", "emailStatus": "test_override", "testMode": true};
  Map<String, dynamic> historyJson = <String, dynamic>{"changes": <Map<String, dynamic>>[]};
  Map<String, dynamic> changedJson = <String, dynamic>{"changed": <String, dynamic>{}};

  @override
  bool get configured => true;

  @override
  Future<Map<String, dynamic>> send(String method, String path, {Object? body, Map<String, String>? query}) async {
    calls.add(Call(method, path, body, query));
    if (failWith != null) throw failWith!;
    if (path.endsWith("/preview")) return previewJson;
    if (path == "/orders/changed") return changedJson;
    if (method == "GET") return historyJson;
    return submitJson;
  }
}

Strings _strings() {
  final values = <String, String>{};
  kOriginalKeyToArb.forEach((dotted, arb) => values[arb] = dotted.split(".").last);
  return Strings.forTests(values);
}

const Order _to = Order(
  kind: OrderKind.transfer, soNum: "TO555", date: "2026-11-06", shipDate: "2026-11-06", customer: "Lindsay → Gatineau",
  shippingLocationName: "Lindsay", saleLocationName: "Gatineau", truckName: "OPEN GOOSENECK", carrierName: "InterQL", memo: "old memo",
);
const Order _so = Order(
  kind: OrderKind.order, soNum: "SO20448", date: "2026-11-04", shipDate: "2026-11-04", customer: "Deroy", serviceType: "INSTALLATION",
  shippingLocationName: "Ste-Agathe", carrierName: "SADM - Jayson", city: "Saint-Donat",
);

final Order _soId = Order(
  kind: OrderKind.order, soNum: "SO20448", soId: 77, date: "2026-11-04", shipDate: "2026-11-04", customer: "Deroy", serviceType: "INSTALLATION",
  shippingLocationName: "Ste-Agathe", carrierName: "SADM - Jayson", city: "Saint-Donat",
);

final Override _itemsOverride = salesOrderDetailsProvider.overrideWith((ref, id) async => const SalesOrderDetails(
      salesOrderId: "77",
      soNum: "SO20448",
      items: <SalesOrderItem>[
        SalesOrderItem(name: "2x4x8 SPF", sku: "SPF-248", quantity: 10, unit: "pc"),
        SalesOrderItem(name: "Vis 3po", sku: "VIS3", quantity: 200),
      ],
    ));

/// Adds a typed line (no order lines available) and fills it.
Future<void> _addLine(WidgetTester tester, int i, {required String item, String before = "", required String after, String note = ""}) async {
  await tester.ensureVisible(find.byKey(const Key("chg-add-line")));
  await tester.tap(find.byKey(const Key("chg-add-line")));
  await tester.pump();
  await tester.enterText(find.byKey(Key("chg-line-$i-item")), item);
  if (before.isNotEmpty) await tester.enterText(find.byKey(Key("chg-line-$i-before")), before);
  await tester.enterText(find.byKey(Key("chg-line-$i-after")), after);
  if (note.isNotEmpty) await tester.enterText(find.byKey(Key("chg-line-$i-note")), note);
  await tester.pump();
}

Future<void> _continue(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key("chg-continue")));
  await tester.tap(find.byKey(const Key("chg-continue")));
  await _settle(tester);
}

Widget _host(FakeTransport t, Widget home, {List<Override> extra = const <Override>[]}) => ProviderScope(
      overrides: <Override>[orderChangeTransportProvider.overrideWithValue(t), ...extra],
      child: StringsScope(strings: _strings(), child: MaterialApp(home: home)),
    );

Widget _launcher(Order o) => Builder(
      builder: (context) => Scaffold(body: Center(child: ElevatedButton(key: const Key("open"), onPressed: () => showOrderChangeScreen(context, o), child: const Text("open")))),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group("logic", () {
    test("latestSavedValues takes the newest saved value per field, ignores unknown keys", () {
      ChangeGroup g(String id, String at, List<FieldChange> f) => ChangeGroup(changeId: id, changedBy: "x", changedAt: at, reason: "", fields: f);
      final groups = <ChangeGroup>[
        g("2", "2026-11-05T14:00:00.000Z", const <FieldChange>[FieldChange(field: "memo", oldValue: "a", newValue: "second")]),
        g("1", "2026-11-05T13:00:00.000Z", const <FieldChange>[FieldChange(field: "memo", oldValue: "", newValue: "first"), FieldChange(field: "city", oldValue: "A", newValue: "B")]),
      ];
      expect(latestSavedValues(groups, <String>["memo", "truck"]), <String, String>{"memo": "second"});
      expect(latestSavedValues(groups.reversed.toList(), <String>["memo", "city"]), <String, String>{"memo": "second", "city": "B"});
      expect(latestSavedValues(const <ChangeGroup>[], <String>["memo"]), isEmpty);
    });

    test("duplicate server answer parses with testMode", () {
      final r = SubmitResult.fromJson(<String, dynamic>{"duplicate": true, "changeId": "c", "emailStatus": "test_override", "testMode": true});
      expect(r.duplicate, isTrue);
      expect(r.testMode, isTrue);
    });

    test("diffChanges keeps only real changes (trimmed) and edited item lines", () {
      final before = currentValues(_so);
      final after = <String, String>{...before, "memo": "  call before  ", "city": "Saint-Donat", "ship_date": "2026-11-06"};
      final d = diffChanges(before, after, items: const <ItemEdit>[
        ItemEdit(item: "2x4 SPF", from: "10", to: "12"),
        ItemEdit(item: "same", from: "1", to: "1"),
        ItemEdit(item: "", from: "1", to: "2"),
        ItemEdit(item: "2x4 SPF", from: "9", to: "9"),
      ]);
      expect(d.map((c) => c.field).toList(), <String>["ship_date", "memo", "item:2x4 SPF"]);
      expect(d[1].newValue, "call before");
      expect(d[0].oldValue, "2026-11-04");
      expect(d.last.toJson(), <String, String>{"field": "item:2x4 SPF", "old": "10", "new": "12"});
    });

    test("line actions derive from before/after; issues are caught early", () {
      expect(lineActionOf("", "3"), "added");
      expect(lineActionOf("0", "3"), "added");
      expect(lineActionOf("5", "0"), "removed");
      expect(lineActionOf("10", "8"), "changed");
      expect(lineActionLabel("removed", french: true), "Retiré");
      expect(lineActionLabel("added", french: false), "Added");
      expect(lineIssue(const ChangeLine(item: "2x4", before: "10", after: "8")), isNull);
      expect(lineIssue(const ChangeLine(item: "2x4", after: "8")), isNull, reason: "blank before = 0 = added");
      expect(lineIssue(const ChangeLine(item: "", after: "8")), "item");
      expect(lineIssue(ChangeLine(item: "x" * 71, after: "8")), "item");
      expect(lineIssue(const ChangeLine(item: "a", before: "1.5", after: "8")), "before");
      expect(lineIssue(const ChangeLine(item: "a", before: "1", after: "")), "after");
      expect(lineIssue(const ChangeLine(item: "a", before: "1", after: "-2")), "after");
      expect(lineIssue(const ChangeLine(item: "a", before: "4", after: "4")), "same");
      expect(firstLineIssue(const <ChangeLine>[ChangeLine(item: "a", after: "1"), ChangeLine(item: " A ", after: "2")]), (index: 1, key: "duplicate"));
      expect(firstLineIssue(const <ChangeLine>[ChangeLine(item: "a", after: "1")]), isNull);
      expect(const ChangeLine(item: " 2x4 ", before: " 10", after: "8 ", note: " cassé ").toJson(), <String, String>{"item": "2x4", "before": "10", "after": "8", "note": "cassé"});
    });

    test("history entries: line changes read as Article : avant → après (action) — note; legacy field entries and notes still render", () {
      final line = FieldChange.fromJson(<String, dynamic>{"field": "item:2x4", "old": "10", "new": "8", "note": "cassé"});
      expect(line.isItem, isTrue);
      expect(line.summary(french: true), "2x4 : 10 → 8 (Quantité modifiée) — cassé");
      expect(const FieldChange(field: "item:Vis", oldValue: "0", newValue: "20").summary(french: false), "Vis : 0 → 20 (Added)");
      expect(const FieldChange(field: "item:Clous", oldValue: "4", newValue: "0").summary(french: true), "Clous : 4 → 0 (Retiré)");
      expect(const FieldChange(field: "memo", oldValue: "a", newValue: "b").summary(french: false), "Memo : a → b");
      expect(const FieldChange(field: "ship_date", oldValue: "2026-11-04", newValue: "2026-11-06").summary(french: true), "Date d'expédition : 2026-11-04 → 2026-11-06");
      expect(const FieldChange(field: "note", oldValue: "", newValue: "Livrer après 14h").summary(french: true), "Livrer après 14h");
    });

    test("fields depend on the order kind", () {
      final so = fieldsFor(_so).map((f) => f.key);
      final to = fieldsFor(_to).map((f) => f.key);
      expect(so, contains("customer"));
      expect(so, isNot(contains("receiving_location")));
      expect(to, contains("receiving_location"));
      expect(to, isNot(contains("customer")));
    });

    test("labels are bilingual and item labels readable", () {
      const c = FieldChange(field: "item:2x4", oldValue: "1", newValue: "2");
      expect(c.label(french: true), "Article : 2x4");
      expect(c.label(french: false), "Item: 2x4");
      expect(const FieldChange(field: "ship_date", oldValue: "", newValue: "").label(french: false), "Ship date");
      expect(roleLabel("receiver", french: true), "Division réceptrice");
    });

    test("order context sends the places the server needs; transfers also send the receiving place", () {
      expect(orderContext(_to), <String, String>{"shippingLocationName": "Lindsay", "saleLocationName": "Gatineau", "carrierName": "InterQL"});
      expect(orderContext(_so)["saleLocationName"], isNull);
      expect(orderContext(_so)["shippingLocationName"], "Ste-Agathe");
    });

    test("shortStamp trims ISO timestamps", () {
      expect(shortStamp("2026-11-05T14:03:00.000Z"), "2026-11-05 14:03");
      expect(shortStamp("weird"), "weird");
    });
  });

  group("service", () {
    test("preview, submit, history and changed speak the server's routes", () async {
      final t = FakeTransport();
      t.historyJson = <String, dynamic>{
        "changes": <Map<String, dynamic>>[
          <String, dynamic>{"changeId": "c9", "changedBy": "Gat - Sam", "changedAt": "2026-11-05T10:00:00Z", "reason": "r", "fields": <Map<String, dynamic>>[<String, dynamic>{"field": "memo", "old": "a", "new": "b"}]},
        ],
      };
      t.changedJson = <String, dynamic>{"changed": <String, dynamic>{"TO555": <String, dynamic>{"count": 2, "lastBy": "x", "lastAt": "y"}}};
      final s = OrderChangeService(transport: t);

      final p = await s.preview(_to);
      expect(t.calls.last.method, "POST");
      expect(t.calls.last.path, "/orders/TO555/changes/preview");
      expect((t.calls.last.body as Map)["context"], containsPair("saleLocationName", "Gatineau"));
      expect(p.testMode, isTrue);
      expect(p.recipients.map((r) => r.email), <String>["lindsay@groupeql.com", "sadm@groupeql.com"]);
      expect(p.recipients[1].roles, <String>["carrier", "dispatcher"]);

      final r = await s.submit(_to, const <FieldChange>[FieldChange(field: "memo", oldValue: "old memo", newValue: "new")], reason: " because ");
      expect(t.calls.last.path, "/orders/TO555/changes");
      final body = t.calls.last.body as Map;
      expect(body["reason"], "because");
      expect((body["changes"] as List).single, <String, String>{"field": "memo", "old": "old memo", "new": "new"});
      expect(r.changeId, "c1");
      expect(r.emailFailed, isFalse);

      await s.submitLines(_to, const <ChangeLine>[ChangeLine(item: " 2x4 ", before: "10", after: "8", note: "cassé"), ChangeLine(item: "Vis", after: "3")], note: " mémo ");
      expect(t.calls.last.path, "/orders/TO555/changes");
      final lb = t.calls.last.body as Map;
      expect(lb["reason"], "mémo");
      expect(lb.containsKey("changes"), isFalse);
      expect((lb["lines"] as List).first, <String, String>{"item": "2x4", "before": "10", "after": "8", "note": "cassé"});
      expect((lb["lines"] as List).last, <String, String>{"item": "Vis", "before": "", "after": "3"});
      expect(lb["context"], containsPair("saleLocationName", "Gatineau"));

      final h = await s.history("to555");
      expect(t.calls.last.method, "GET");
      expect(t.calls.last.path, "/orders/TO555/changes");
      expect(h.single.changedBy, "Gat - Sam");
      expect(h.single.fields.single.newValue, "b");

      final c = await s.changed(<String>["TO555", "to555", "SO1"]);
      expect(t.calls.last.query, <String, String>{"nums": "TO555,SO1"});
      expect(c["TO555"]!.count, 2);
      expect(await s.changed(<String>[]), isEmpty);
    });

    test("emailFailed flags a saved change whose notice did not go out", () {
      expect(const SubmitResult(changeId: "c", emailStatus: "failed", duplicate: false, testMode: false).emailFailed, isTrue);
      expect(const SubmitResult(changeId: "c", emailStatus: "sent", duplicate: false, testMode: false).emailFailed, isFalse);
    });

    test("errors map to plain categories", () {
      expect(changeErrorKey(const BackendNotConfigured()), "not_configured");
      expect(changeErrorKey(const BackendException(401, "x")), "session");
      expect(changeErrorKey(const BackendException(403, "x")), "forbidden");
      expect(changeErrorKey(const BackendException(429, "x")), "too_many");
      expect(changeErrorKey(const BackendException(422, "x")), "invalid");
      expect(changeErrorKey(const BackendException(0, "x")), "network");
      expect(changeErrorKey(StateError("x")), "error");
    });
  });

  group("widgets", () {
    testWidgets("form: identity read-only, no header fields; typed lines -> confirmation lists who is notified (TEST banner) -> save sends the lines", (tester) async {
      final t = FakeTransport();
      await tester.pumpWidget(_host(t, _launcher(_to)));
      await tester.tap(find.byKey(const Key("open")));
      await _settle(tester);

      expect(find.byKey(const Key("chg-identity")), findsOneWidget);
      expect(find.text("TO555"), findsWidgets);
      expect(find.textContaining("OPEN GOOSENECK"), findsOneWidget);
      expect(find.textContaining("InterQL"), findsOneWidget);
      for (final k in <String>["memo", "ship_date", "truck", "carrier", "customer", "address", "phone", "city", "service_type", "status_note"]) {
        expect(find.byKey(Key("chg-field-$k")), findsNothing, reason: "header field $k is no longer editable");
      }
      expect(find.byKey(const Key("chg-no-items-hint")), findsOneWidget, reason: "no order lines: manual entry + a hint");
      expect(find.byKey(const Key("chg-pick-line")), findsNothing);

      // nothing entered yet
      await _continue(tester);
      expect(find.byKey(const Key("chg-error")), findsOneWidget);
      expect(t.calls.where((c) => c.method != "GET"), isEmpty);

      await _addLine(tester, 0, item: "2x4", before: "10", after: "12", note: "client");
      expect(find.byKey(const Key("chg-line-0-action")), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key("chg-line-0-action"))).data, "Quantité modifiée");
      await _addLine(tester, 1, item: "Vis", after: "20");
      expect(tester.widget<Text>(find.byKey(const Key("chg-line-1-action"))).data, "Ajouté");
      await tester.enterText(find.byKey(const Key("chg-note")), "client asked");
      await _continue(tester);

      expect(find.byKey(const Key("chg-confirm-dialog")), findsOneWidget);
      expect(find.textContaining("2x4 : 10 → 12 (Quantité modifiée) — client"), findsOneWidget);
      expect(find.textContaining("Vis : 0 → 20 (Ajouté)"), findsOneWidget);
      expect(find.byKey(const Key("chg-confirm-note")), findsOneWidget);
      expect(find.byKey(const Key("chg-recipient-lindsay@groupeql.com")), findsOneWidget);
      expect(find.byKey(const Key("chg-recipient-sadm@groupeql.com")), findsOneWidget);
      expect(find.byKey(const Key("chg-test-banner")), findsOneWidget);
      expect(find.textContaining("communication@groupeql.com"), findsOneWidget);
      expect(t.calls.where((c) => c.method != "GET").map((c) => c.path), <String>["/orders/TO555/changes/preview"], reason: "nothing is saved before the user confirms");

      await tester.tap(find.byKey(const Key("chg-confirm")));
      await _settle(tester);
      expect(t.calls.last.path, "/orders/TO555/changes");
      final body = t.calls.last.body as Map;
      expect((body["lines"] as List).cast<Map>().map((m) => m["item"]).toList(), <String>["2x4", "Vis"]);
      expect((body["lines"] as List).first, <String, String>{"item": "2x4", "before": "10", "after": "12", "note": "client"});
      expect(body["reason"], "client asked");
      expect(body.containsKey("changes"), isFalse);
      expect(find.byKey(const Key("chg-title")), findsNothing, reason: "screen closes after saving");
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets("a note alone is enough; line problems are explained before anything is sent", (tester) async {
      final t = FakeTransport();
      await tester.pumpWidget(_host(t, _launcher(_so)));
      await tester.tap(find.byKey(const Key("open")));
      await _settle(tester);

      await _addLine(tester, 0, item: "2x4", before: "5", after: "5");
      await _continue(tester);
      expect(find.textContaining("n'a pas changé"), findsOneWidget);
      await tester.enterText(find.byKey(const Key("chg-line-0-after")), "");
      await _continue(tester);
      expect(find.textContaining("nouvelle quantité"), findsOneWidget);
      await _addLine(tester, 1, item: " 2X4 ", after: "2");
      await tester.enterText(find.byKey(const Key("chg-line-0-after")), "7");
      await _continue(tester);
      expect(find.textContaining("déjà dans la liste"), findsOneWidget);
      expect(t.calls.where((c) => c.method != "GET"), isEmpty, reason: "invalid lines never reach the server");

      // remove both lines, note only
      await tester.ensureVisible(find.byKey(const Key("chg-line-1-remove")));
      await tester.tap(find.byKey(const Key("chg-line-1-remove")));
      await tester.pump();
      await tester.tap(find.byKey(const Key("chg-line-0-remove")));
      await tester.pump();
      expect(find.byKey(const Key("chg-line-0")), findsNothing);
      await _continue(tester);
      expect(find.byKey(const Key("chg-error")), findsOneWidget, reason: "no lines and no note");
      await tester.enterText(find.byKey(const Key("chg-note")), "Livrer après 14h");
      await _continue(tester);
      expect(find.byKey(const Key("chg-confirm-dialog")), findsOneWidget);
      await tester.tap(find.byKey(const Key("chg-confirm")));
      await _settle(tester);
      final body = t.calls.last.body as Map;
      expect(body["lines"], isEmpty);
      expect(body["reason"], "Livrer après 14h");
    });

    testWidgets("with the order's lines available: pick a line, only the new quantity is typed; Après 0 = removed; used lines are disabled", (tester) async {
      final t = FakeTransport();
      await tester.pumpWidget(_host(t, _launcher(_soId), extra: <Override>[_itemsOverride]));
      await tester.tap(find.byKey(const Key("open")));
      await _settle(tester);

      expect(find.byKey(const Key("chg-no-items-hint")), findsNothing);
      await tester.ensureVisible(find.byKey(const Key("chg-pick-line")));
      await tester.tap(find.byKey(const Key("chg-pick-line")));
      await _settle(tester);
      expect(find.text("2x4x8 SPF"), findsOneWidget);
      expect(find.text("SPF-248"), findsOneWidget);
      expect(find.text("10 pc"), findsOneWidget);
      await tester.tap(find.byKey(const Key("chg-pick-0")));
      await _settle(tester);

      // the article and "before" come from the order and are not editable
      expect(find.byKey(const Key("chg-line-0-item")), findsOneWidget);
      expect(find.byType(TextField).evaluate().where((e) => (e.widget as TextField).key == const Key("chg-line-0-item")), isEmpty);
      expect(find.textContaining("Avant : 10"), findsOneWidget);
      await tester.enterText(find.byKey(const Key("chg-line-0-after")), "0");
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const Key("chg-line-0-action"))).data, "Retiré");

      await tester.ensureVisible(find.byKey(const Key("chg-pick-line")));
      await tester.tap(find.byKey(const Key("chg-pick-line")));
      await _settle(tester);
      expect(tester.widget<ListTile>(find.byKey(const Key("chg-pick-0"))).enabled, isFalse, reason: "already in the list");
      await tester.tap(find.byKey(const Key("chg-pick-1")));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key("chg-line-1-after")), "150");
      await _continue(tester);
      await tester.tap(find.byKey(const Key("chg-confirm")));
      await _settle(tester);
      final lines = ((t.calls.last.body as Map)["lines"] as List).cast<Map>();
      expect(lines[0], <String, String>{"item": "2x4x8 SPF", "before": "10", "after": "0"});
      expect(lines[1], <String, String>{"item": "Vis 3po", "before": "200", "after": "150"});
    });

    testWidgets("a carrier's confirmation lists roles and divisions only (the server hides mailboxes)", (tester) async {
      final t = FakeTransport();
      t.previewJson = t.maskedPreview;
      await tester.pumpWidget(_host(t, _launcher(_so)));
      await tester.tap(find.byKey(const Key("open")));
      await _settle(tester);
      await _addLine(tester, 0, item: "2x4", before: "1", after: "2");
      await tester.ensureVisible(find.byKey(const Key("chg-continue")));
      await tester.tap(find.byKey(const Key("chg-continue")));
      await _settle(tester);
      expect(find.byKey(const Key("chg-recipient-creator")), findsOneWidget);
      expect(find.textContaining("@groupeql.com"), findsNothing);
      expect(find.textContaining("lindsay — Division créatrice"), findsOneWidget);
    });

    testWidgets("going back from the confirmation saves nothing", (tester) async {
      final t = FakeTransport();
      await tester.pumpWidget(_host(t, _launcher(_so)));
      await tester.tap(find.byKey(const Key("open")));
      await _settle(tester);
      await _addLine(tester, 0, item: "2x4", before: "1", after: "2");
      await tester.ensureVisible(find.byKey(const Key("chg-continue")));
      await tester.tap(find.byKey(const Key("chg-continue")));
      await _settle(tester);
      await tester.tap(find.byKey(const Key("chg-confirm-back")));
      await _settle(tester);
      expect(t.calls.where((c) => c.method != "GET" && !c.path.endsWith("/preview")), isEmpty);
      expect(find.byKey(const Key("chg-title")), findsOneWidget);
    });

    testWidgets("an unresolved division is shown as a warning and a server error is explained in plain words", (tester) async {
      final t = FakeTransport()..previewJson = <String, dynamic>{"recipients": <dynamic>[], "deliveredTo": <String>[], "testMode": false, "unresolved": <String>["origin: Mars"]};
      await tester.pumpWidget(_host(t, _launcher(_so)));
      await tester.tap(find.byKey(const Key("open")));
      await _settle(tester);
      await _addLine(tester, 0, item: "2x4", before: "1", after: "2");
      await tester.ensureVisible(find.byKey(const Key("chg-continue")));
      await tester.tap(find.byKey(const Key("chg-continue")));
      await _settle(tester);
      expect(find.byKey(const Key("chg-unresolved")), findsOneWidget);
      expect(find.byKey(const Key("chg-test-banner")), findsNothing);
      t.failWith = const BackendException(403, "role_not_allowed");
      await tester.tap(find.byKey(const Key("chg-confirm")));
      await _settle(tester);
      expect(find.byKey(const Key("chg-error")), findsOneWidget);
      expect(find.textContaining("pas la vôtre"), findsOneWidget);
    });

    testWidgets("preview failure keeps the form open with a message", (tester) async {
      final t = FakeTransport()..failWith = const BackendNotConfigured();
      await tester.pumpWidget(_host(t, _launcher(_so)));
      await tester.tap(find.byKey(const Key("open")));
      await _settle(tester);
      await _addLine(tester, 0, item: "2x4", before: "1", after: "2");
      await tester.ensureVisible(find.byKey(const Key("chg-continue")));
      await tester.tap(find.byKey(const Key("chg-continue")));
      await _settle(tester);
      expect(find.byKey(const Key("chg-error")), findsOneWidget);
      expect(find.byKey(const Key("chg-confirm-dialog")), findsNothing);
    });

    testWidgets("history sheet lists who, when, field and old -> new; empty state too", (tester) async {
      final t = FakeTransport();
      t.historyJson = <String, dynamic>{
        "changes": <Map<String, dynamic>>[
          <String, dynamic>{"changeId": "c9", "changedBy": "Gat - Sam", "changedAt": "2026-11-05T10:00:00Z", "reason": "client asked", "fields": <Map<String, dynamic>>[<String, dynamic>{"field": "ship_date", "old": "2026-11-04", "new": "2026-11-06"}, <String, dynamic>{"field": "item:2x4", "old": "10", "new": "8", "note": "cassé"}]},
        ],
      };
      await tester.pumpWidget(_host(t, const Scaffold(body: OrderHistorySheet(orderNum: "SO20448"))));
      await _settle(tester);
      expect(find.byKey(const Key("history-c9")), findsOneWidget);
      expect(find.textContaining("Gat - Sam"), findsOneWidget);
      expect(find.textContaining("2026-11-05 10:00"), findsOneWidget);
      expect(find.textContaining("2026-11-04 → 2026-11-06"), findsOneWidget, reason: "legacy field entries still render");
      expect(find.textContaining("2x4 : 10 → 8 (Quantité modifiée) — cassé"), findsOneWidget);

      final empty = FakeTransport();
      await tester.pumpWidget(_host(empty, const Scaffold(body: OrderHistorySheet(orderNum: "SO1"))));
      await _settle(tester);
      expect(find.byKey(const Key("history-empty")), findsOneWidget);
    });

    testWidgets("calendar badge shows only for orders that carry changes", (tester) async {
      final t = FakeTransport();
      await tester.pumpWidget(_host(
        t,
        const Scaffold(body: Column(children: <Widget>[OrderChangedBadge(orderNum: "SO20448"), OrderChangedBadge(orderNum: "SO1")])),
        extra: <Override>[
          changedOrdersProvider.overrideWith((ref) async => <String, ChangedInfo>{"SO20448": const ChangedInfo(count: 2, lastBy: "x", lastAt: "y")}),
        ],
      ));
      await _settle(tester);
      expect(find.byKey(const Key("changed-badge-SO20448")), findsOneWidget);
      expect(find.byKey(const Key("changed-badge-SO1")), findsNothing);
      expect(find.textContaining("Modifié"), findsOneWidget);
    });

    testWidgets("ticket sheet: Change order + History actions, and the Changed badge when the order has history", (tester) async {
      final t = FakeTransport();
      t.historyJson = <String, dynamic>{
        "changes": <Map<String, dynamic>>[
          <String, dynamic>{"changeId": "c9", "changedBy": "Gat - Sam", "changedAt": "2026-11-05T10:00:00Z", "reason": "", "fields": <Map<String, dynamic>>[<String, dynamic>{"field": "memo", "old": "", "new": "b"}]},
        ],
      };
      final service = TicketService(
        fetch: (String? token, String num, {void Function(double? fraction)? onDownload}) async => const TicketHttpResult(200, <int>[1, 2, 3]),
        tokens: _Tokens(),
        retryDelay: Duration.zero,
      );
      await tester.pumpWidget(_host(
        t,
        const TicketSheet(orderNum: "SO20448", order: _so),
        extra: <Override>[
          ticketServiceProvider.overrideWithValue(service),
          ticketPdfBuilderProvider.overrideWithValue((context, Uint8List bytes, String name) => Text("PDF:" + name)),
        ],
      ));
      await _settle(tester);
      expect(find.byKey(const Key("ticket-change")), findsOneWidget);
      expect(find.byKey(const Key("ticket-history")), findsOneWidget);
      expect(find.byKey(const Key("ticket-changed-badge")), findsOneWidget);

      await tester.tap(find.byKey(const Key("ticket-change")));
      await _settle(tester);
      expect(find.byKey(const Key("chg-title")), findsOneWidget);
    });

    testWidgets("ticket sheet without an order hides Change order and shows no badge when there is no history", (tester) async {
      final t = FakeTransport();
      final service = TicketService(
        fetch: (String? token, String num, {void Function(double? fraction)? onDownload}) async => const TicketHttpResult(200, <int>[1]),
        tokens: _Tokens(),
        retryDelay: Duration.zero,
      );
      await tester.pumpWidget(_host(
        t,
        const TicketSheet(orderNum: "SO1"),
        extra: <Override>[
          ticketServiceProvider.overrideWithValue(service),
          ticketPdfBuilderProvider.overrideWithValue((context, Uint8List bytes, String name) => Text("PDF:" + name)),
        ],
      ));
      await _settle(tester);
      expect(find.byKey(const Key("ticket-change")), findsNothing);
      expect(find.byKey(const Key("ticket-changed-badge")), findsNothing);
      expect(find.byKey(const Key("ticket-history")), findsOneWidget);
    });
  });
}

class _Tokens implements TicketTokens {
  @override
  String? primaryToken() => "own";
  @override
  String? transferToken(String toNum) => null;
  @override
  String? carrierName() => "Gat - Sam";
  @override
  List<String> sadmTruckTokens() => <String>[];
}
