import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";

import "package:quai_calendar/api/api_client.dart";
import "package:quai_calendar/api/orders_api.dart";

class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(this.status);
  final int status;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromString("{}", status, headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      });
  @override
  void close({bool force = false}) {}
}

ApiClient _client(int status) => ApiClient(
    dio: Dio()..httpClientAdapter = _StatusAdapter(status),
    baseUrl: "https://example.test");

void main() {
  group("an expired token is never an empty calendar", () {
    test("fetchShipCalendarOrders throws UnauthorizedException on 401", () {
      expect(() => _client(401).fetchShipCalendarOrders("t"),
          throwsA(isA<UnauthorizedException>()));
    });
    test("... and on 403", () {
      expect(() => _client(403).fetchShipCalendarOrders("t"),
          throwsA(isA<UnauthorizedException>()));
    });
    test("a server error still degrades to an empty list (reference behaviour)",
        () async {
      expect(await _client(500).fetchShipCalendarOrders("t"), isEmpty);
    });
    test("shipOrders throws UnauthorizedException on 401", () {
      expect(() => _client(401).shipOrders("t"),
          throwsA(isA<UnauthorizedException>()));
    });
  });
}
