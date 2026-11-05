import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/admin_aggregate.dart";
import "package:quai_calendar/i18n/i18n.dart";
import "package:quai_calendar/l10n/key_map.dart";
import "package:quai_calendar/models/order.dart";
import "package:quai_calendar/state/providers.dart";
import "package:quai_calendar/widgets/admin_aggregate_bar.dart";

class _Adapter implements HttpClientAdapter {
  _Adapter(this.status, this.body);
  final int status;
  final Object body;
  final List<RequestOptions> seen = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    seen.add(options);
    return ResponseBody.fromString(jsonEncode(body), status, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

AdminAggregateService _service(_Adapter a) =>
    AdminAggregateService(url: "https://x.test/admin/orders-aggregate", token: () => "sess", dio: Dio()..httpClientAdapter = a);

Map<String, dynamic> _json() => <String, dynamic>{
      "generatedAt": "2026-11-05T12:00:00.000Z",
      "refreshing": false,
      "trucks": <dynamic>[
        <String, dynamic>{
          "name": "Gat - Sam", "displayName": "Gat - Sam", "status": "ok", "ok": true, "lastRefreshedAt": "2026-11-05T12:00:00.000Z",
          "orders": <String, dynamic>{
            "ship": <dynamic>[
              <String, dynamic>{"soNum": "SO1", "soId": 1, "serviceEventId": 11, "date": "2026-11-06", "customer": "A"},
              <String, dynamic>{"soNum": "SO2", "soId": 2, "serviceEventId": 12, "date": "2026-11-06", "customer": "B"},
            ],
            "transfer": <dynamic>[],
          },
        },
        <String, dynamic>{
          "name": "RIDEAU GOOSENECK", "displayName": "InterQL", "status": "stale", "ok": false, "lastRefreshedAt": "2026-11-05T11:00:00.000Z",
          "orders": <String, dynamic>{
            "ship": <dynamic>[],
            "transfer": <dynamic>[
              <String, dynamic>{"toNum": "TO5", "toId": 5, "serviceEventId": 55, "date": "2026-11-07", "fromLocationName": "X", "toLocationName": "Y"},
              <String, dynamic>{"toNum": "TO6", "toId": 6, "isShell": true},
            ],
          },
        },
        <String, dynamic>{
          "name": "Québec - Marc", "displayName": "Québec - Marc", "status": "failed", "ok": false, "lastRefreshedAt": null,
          "orders": <String, dynamic>{"ship": <dynamic>[], "transfer": <dynamic>[]},
        },
        <String, dynamic>{
          "name": "SADM - Éric", "displayName": "SADM - Éric", "status": "pending", "ok": false, "lastRefreshedAt": null,
          "orders": <String, dynamic>{"ship": <dynamic>[], "transfer": <dynamic>[]},
        },
      ],
    };

Strings _strings() {
  final values = <String, String>{};
  kOriginalKeyToArb.forEach((dotted, arb) => values[arb] = dotted.split(".").last);
  return Strings.forTests(values);
}

void main() {
  test("adminAggregateUrlFor derives the route from the Pick-ups proxy URL", () {
    expect(adminAggregateUrlFor("https://h.example/middleware/events"), "https://h.example/admin/orders-aggregate");
    expect(adminAggregateUrlFor("https://h.example/"), "https://h.example/admin/orders-aggregate");
    expect(adminAggregateUrlFor(""), "");
  });

  test("toOrdersLoad: server rows become the same Orders as loadAggregate; failed trucks are listed", () {
    final agg = AdminAggregate.fromJson(_json());
    expect(agg.hasData, isTrue);
    expect(agg.generatedAt, DateTime.utc(2026, 11, 5, 12));
    final load = agg.toOrdersLoad();
    expect(load.orders.map((o) => o.soNum).toList(), <String>["SO1", "SO2", "TO5"], reason: "the shell transfer row is dropped");
    expect(load.orders.first.carrierName, "Gat - Sam");
    final to = load.orders.last;
    expect(to.kind, OrderKind.transfer);
    expect(to.carrierName, "InterQL", reason: "Gooseneck trucks are shown under the shared calendar name");
    expect(load.failedTrucks, <String>["Québec - Marc", "SADM - Éric"], reason: "stale trucks keep their data; trucks with none are 'not loaded'");
    expect(load.unauthorized, isFalse);
  });

  test("an aggregate with no data at all reports hasData=false (the app then falls back)", () {
    final agg = AdminAggregate.fromJson(<String, dynamic>{
      "generatedAt": null,
      "trucks": <dynamic>[<String, dynamic>{"name": "A", "status": "pending", "lastRefreshedAt": null, "orders": <String, dynamic>{}}],
    });
    expect(agg.hasData, isFalse);
    expect(agg.generatedAt, isNull);
  });

  test("fetch: sends the session token, parses 200; any other status or garbage -> null", () async {
    final ok = _Adapter(200, _json());
    final agg = await _service(ok).fetch();
    expect(agg!.trucks.length, 4);
    expect(ok.seen.single.headers["Authorization"], "Bearer sess");
    expect(ok.seen.single.method, "GET");
    expect(await _service(_Adapter(403, <String, dynamic>{"error": "forbidden"})).fetch(), isNull);
    expect(await _service(_Adapter(502, <String, dynamic>{})).fetch(), isNull);
    expect(await _service(_Adapter(200, <dynamic>[1, 2])).fetch(), isNull);
  });

  test("requestRefresh maps 202/429/other", () async {
    expect(await _service(_Adapter(202, <String, dynamic>{"started": true})).requestRefresh(), AggregateRefresh.started);
    expect(await _service(_Adapter(202, <String, dynamic>{"started": false})).requestRefresh(), AggregateRefresh.alreadyRunning);
    expect(await _service(_Adapter(429, <String, dynamic>{})).requestRefresh(), AggregateRefresh.rateLimited);
    expect(await _service(_Adapter(403, <String, dynamic>{})).requestRefresh(), AggregateRefresh.failed);
    final a = _Adapter(202, <String, dynamic>{"started": true});
    await _service(a).requestRefresh();
    expect(a.seen.single.method, "POST");
    expect(a.seen.single.uri.path, "/admin/orders-aggregate/refresh");
  });

  test("ageText: just now / N min, French and English", () {
    final s = _strings();
    final now = DateTime.utc(2026, 11, 5, 12, 10);
    expect(AdminAggregateBar.ageText(s, DateTime.utc(2026, 11, 5, 12, 5), now), "Données à jour il y a 5 min");
    expect(AdminAggregateBar.ageText(s, DateTime.utc(2026, 11, 5, 12, 10), now), "Données à jour à l'instant");
    expect(AdminAggregateBar.ageText(s, null, now), "Données en préparation");
    final en = Strings.forTests(const <String, String>{}, locale: const Locale("en"));
    expect(AdminAggregateBar.ageText(en, DateTime.utc(2026, 11, 5, 12, 5), now), "Updated 5 min ago");
  });

  testWidgets("the bar shows the age and a Refresh button; hidden when there is no aggregate; disabled while refreshing", (tester) async {
    Widget host(AdminAggregate? agg, {bool refreshing = false}) => ProviderScope(
          key: UniqueKey(), // a fresh container each time: overrides of a mounted scope are not re-applied
          overrides: <Override>[
            adminAggregateProvider.overrideWith((ref) async => agg),
            adminRefreshingProvider.overrideWith((ref) => refreshing),
          ],
          child: StringsScope(strings: _strings(), child: const MaterialApp(home: Scaffold(body: AdminAggregateBar()))),
        );

    await tester.pumpWidget(host(AdminAggregate.fromJson(_json())));
    await tester.pump();
    expect(find.byKey(const Key("admin-aggregate-age")), findsOneWidget);
    expect(find.textContaining("Données à jour"), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const Key("admin-aggregate-refresh"))).onPressed, isNotNull);

    await tester.pumpWidget(host(AdminAggregate.fromJson(_json()), refreshing: true));
    await tester.pump();
    expect(tester.widget<TextButton>(find.byKey(const Key("admin-aggregate-refresh"))).onPressed, isNull);
    expect(find.textContaining("mise à jour en cours"), findsOneWidget);

    await tester.pumpWidget(host(null));
    await tester.pump();
    expect(find.byKey(const Key("admin-aggregate-age")), findsNothing);
    expect(find.byKey(const Key("admin-aggregate-refresh")), findsNothing);
  });
}
