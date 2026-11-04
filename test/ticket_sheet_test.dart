import "dart:async";
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/ticket_service.dart";
import "package:quai_calendar/i18n/i18n.dart";
import "package:quai_calendar/l10n/key_map.dart";
import "package:quai_calendar/pdf/pdf_ports.dart";
import "package:quai_calendar/screens/ticket_sheet.dart";
import "package:quai_calendar/state/providers.dart";
import "package:quai_calendar/theme.dart";

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

class _Actions implements TicketFileActions {
  int printed = 0;
  int downloaded = 0;
  @override
  Future<void> printPdf(Uint8List bytes, String name) async => printed++;
  @override
  Future<void> download(Uint8List bytes, String name) async => downloaded++;
}

Strings _strings() {
  final values = <String, String>{};
  kOriginalKeyToArb
      .forEach((dotted, arb) => values[arb] = dotted.split(".").last);
  return Strings.forTests(values);
}

TicketService _service(Future<TicketHttpResult> Function() answer) =>
    TicketService(
      fetch: (String? token, String ticketNum,
              {void Function(double? fraction)? onDownload}) =>
          answer(),
      tokens: _Tokens(),
      retryDelay: Duration.zero,
    );

Widget _host(TicketService svc, _Actions actions, {Widget? home}) =>
    ProviderScope(
      overrides: <Override>[
        ticketServiceProvider.overrideWithValue(svc),
        ticketPdfBuilderProvider.overrideWithValue(
            (context, bytes, name) => Text("PDF:${bytes.length}:$name")),
        ticketFileActionsProvider.overrideWithValue(actions),
      ],
      child: StringsScope(
        strings: _strings(),
        child: MaterialApp(home: home ?? const TicketSheet(orderNum: "SO1")),
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets("shows honest, rising progress while the document is prepared",
      (tester) async {
    final gate = Completer<TicketHttpResult>();
    await tester.pumpWidget(_host(_service(() => gate.future), _Actions()));
    await tester.pump();
    expect(find.byKey(const Key("ticket-progress")), findsOneWidget);
    expect(find.textContaining("NetSuite"), findsOneWidget);

    final before = tester
        .widget<LinearProgressIndicator>(
            find.byKey(const Key("ticket-progress")))
        .value!;
    await tester.pump(const Duration(seconds: 4));
    final after = tester
        .widget<LinearProgressIndicator>(
            find.byKey(const Key("ticket-progress")))
        .value!;
    expect(after, greaterThan(before));
    expect(after, greaterThan(0.3));
    expect(after, lessThanOrEqualTo(0.7));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("print and download are disabled until the PDF is ready",
      (tester) async {
    final gate = Completer<TicketHttpResult>();
    await tester.pumpWidget(_host(_service(() => gate.future), _Actions()));
    await tester.pump();
    expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key("ticket-print")))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key("ticket-download")))
            .onPressed,
        isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      "once loaded it shows the PDF view, hides the progress bar, and enables print + download",
      (tester) async {
    final actions = _Actions();
    await tester.pumpWidget(_host(
        _service(() async => const TicketHttpResult(200, <int>[1, 2, 3])),
        actions));
    await _settle(tester);

    expect(find.text("PDF:3:SO1"), findsOneWidget);
    expect(find.byKey(const Key("ticket-progress")), findsNothing);

    await tester.tap(find.byKey(const Key("ticket-print")));
    await tester.pump();
    await tester.tap(find.byKey(const Key("ticket-download")));
    await tester.pump();
    expect(actions.printed, 1);
    expect(actions.downloaded, 1);
  });

  testWidgets(
      "a missing ticket shows the friendly message and a retry button, not a blank screen",
      (tester) async {
    await tester.pumpWidget(
        _host(_service(() async => const TicketHttpResult(404)), _Actions()));
    await _settle(tester);
    expect(find.byKey(const Key("ticket-error")), findsOneWidget);
    expect(find.textContaining("temporairement indisponible"), findsOneWidget);
    expect(find.byKey(const Key("ticket-retry")), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key("ticket-print")))
            .onPressed,
        isNull);
  });

  testWidgets("a stale session says so", (tester) async {
    await tester.pumpWidget(
        _host(_service(() async => const TicketHttpResult(401)), _Actions()));
    await _settle(tester);
    expect(find.textContaining("Session expirée"), findsOneWidget);
  });

  testWidgets("the Close button is big, red and always on screen",
      (tester) async {
    final gate = Completer<TicketHttpResult>();
    await tester.pumpWidget(_host(_service(() => gate.future), _Actions()));
    await tester.pump();
    final close = find.byKey(const Key("ticket-close"));
    expect(close, findsOneWidget);
    expect(tester.getSize(close).height, greaterThanOrEqualTo(44));
    final style = tester.widget<FilledButton>(close).style!;
    expect(style.backgroundColor!.resolve(<WidgetState>{}), CardPalette.past);
    expect(find.text("Fermer / Close"), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("tapping Close returns to the previous screen", (tester) async {
    final home = Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
              onPressed: () => showTicketSheet(context, "SO1"),
              child: const Text("open")),
        ),
      ),
    );
    await tester.pumpWidget(_host(
        _service(() async => const TicketHttpResult(200, <int>[1])), _Actions(),
        home: home));
    await tester.tap(find.text("open"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(TicketSheet), findsOneWidget);

    await tester.tap(find.byKey(const Key("ticket-close")));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(TicketSheet), findsNothing);
    expect(find.text("open"), findsOneWidget);
  });
}
