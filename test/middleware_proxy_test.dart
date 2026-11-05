import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/middleware_source.dart";

class _Rec implements HttpClientAdapter {
  _Rec(this.status, this.body);
  final int status;
  final String body;
  final List<RequestOptions> calls = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls.add(options);
    return ResponseBody.fromString(body, status,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        });
  }

  @override
  void close({bool force = false}) {}
}

const _item =
    '{"id":"1","title":"SADM - Ste-Agathe / SO100 / Client / Ramassage","salesOrderId":"100","startDate":"2026-11-03"}';

ProxyMiddlewareSource _src(_Rec r, {String? token = "SESSION.JWT"}) =>
    ProxyMiddlewareSource(
      proxyUrl: "https://x.test/middleware/events",
      token: () => token,
      dio: Dio()..httpClientAdapter = r,
    );

Future<List<Object?>> _ask(_Rec r) async => await _src(r).events("Ste-Agathe",
    from: DateTime(2026, 11, 1), to: DateTime(2026, 11, 7));

void main() {
  group("proxy URL comes from the exchange URL (one dart-define)", () {
    test("exchange URL with /exchange", () {
      expect(
          middlewareProxyUrlFor(
              exchangeUrl: "https://a.up.railway.app/exchange"),
          "https://a.up.railway.app/middleware/events");
    });
    test("bare host, trailing slashes", () {
      expect(middlewareProxyUrlFor(exchangeUrl: "https://a.up.railway.app"),
          "https://a.up.railway.app/middleware/events");
      expect(
          middlewareProxyUrlFor(
              exchangeUrl: "https://a.up.railway.app/exchange/"),
          "https://a.up.railway.app/middleware/events");
    });
    test("override wins; nothing configured stays empty (the tab says so)", () {
      expect(
          middlewareProxyUrlFor(
              exchangeUrl: "https://a/exchange", override: "https://b/p"),
          "https://b/p");
      expect(middlewareProxyUrlFor(exchangeUrl: ""), "");
      expect(const UnconfiguredMiddlewareSource().configured, isFalse);
    });
  });

  group("ProxyMiddlewareSource", () {
    test(
        "sends the SESSION token as bearer and the three query fields, no api key",
        () async {
      final r = _Rec(200, '{"events":[$_item]}');
      final out = await _ask(r);
      expect(out, hasLength(1));
      final c = r.calls.single;
      expect(c.headers["Authorization"], "Bearer SESSION.JWT");
      expect(c.queryParameters["location"], "Ste-Agathe");
      expect(c.queryParameters["from"], "2026-11-01");
      expect(c.queryParameters["to"], "2026-11-07");
      expect(c.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains("x-api-key")));
    });

    test("accepts a bare list too", () async {
      expect(await _ask(_Rec(200, "[$_item]")), hasLength(1));
    });

    test("502 / 401 / 403 / 429 / 503 / junk -> [] and never throws", () async {
      for (final s in <int>[502, 401, 403, 429, 503]) {
        expect(await _ask(_Rec(s, '{"error":"x"}')), isEmpty, reason: "$s");
      }
      expect(await _ask(_Rec(200, "oops")), isEmpty);
    });
  });
}
