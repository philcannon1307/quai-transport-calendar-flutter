import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/supabase_rest_gateway.dart";

/// Records every request and answers 200 with an empty JSON list.
class _Recorder implements HttpClientAdapter {
  final List<RequestOptions> calls = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls.add(options);
    return ResponseBody.fromString("[]", 200, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

const _anon = "ANON-PUBLIC-KEY";
const _session = "SESSION.JWT.VALUE";

SupabaseRestGateway _gw(_Recorder r, {String? session}) => SupabaseRestGateway(
      baseUrl: "https://p.supabase.test/",
      anonKey: _anon,
      sessionToken: () => session,
      dio: Dio()..httpClientAdapter = r,
    );

void main() {
  group("who the database sees", () {
    test("signed in: Authorization is the SESSION token, apikey stays the public key", () async {
      final r = _Recorder();
      await _gw(r, session: _session).insertAdjustment(<String, dynamic>{"id": "x"});
      final h = r.calls.single.headers;
      expect(h["Authorization"], "Bearer $_session");
      expect(h["apikey"], _anon);
      expect(h.containsKey("X-Quai-Session"), isFalse, reason: "no custom header on REST calls (CORS pre-flight)");
    });

    test("signed out: falls back to the public key as bearer", () async {
      final r = _Recorder();
      await _gw(r).insertAdjustment(<String, dynamic>{"id": "x"});
      expect(r.calls.single.headers["Authorization"], "Bearer $_anon");
      expect(r.calls.single.headers["apikey"], _anon);
    });

    test("the email call carries the session both ways", () async {
      final r = _Recorder();
      await _gw(r, session: _session).sendEmail(template: "order-adjustment", idempotencyKey: "k", data: <String, dynamic>{"reportId": "r"});
      final c = r.calls.single;
      expect(c.path, "https://p.supabase.test/functions/v1/send-transactional-email");
      expect(c.headers["Authorization"], "Bearer $_session");
      expect(c.headers["X-Quai-Session"], _session);
      expect(c.data, <String, dynamic>{"templateName": "order-adjustment", "idempotencyKey": "k", "templateData": <String, dynamic>{"reportId": "r"}});
      expect((c.data as Map).containsKey("recipientEmail"), isFalse);
    });

    test("storage uploads use the session too", () async {
      final r = _Recorder();
      await _gw(r, session: _session).uploadFile(bucket: "receipts", path: "2026-11-03/a.jpg", bytes: Uint8List.fromList(<int>[1, 2]), contentType: "image/jpeg");
      expect(r.calls.single.headers["Authorization"], "Bearer $_session");
    });
  });

  group("history snapshot", () {
    test("goes through the upsert_delivery_history function as {rows: [...]}", () async {
      final r = _Recorder();
      final rows = <Map<String, dynamic>>[<String, dynamic>{"so_num": "SO1", "carrier_name": "Gat - Sam"}];
      await _gw(r, session: _session).upsertHistory(rows);
      final c = r.calls.single;
      expect(c.method, "POST");
      expect(c.path, "https://p.supabase.test/rest/v1/rpc/upsert_delivery_history");
      expect(jsonDecode(jsonEncode(c.data)), <String, dynamic>{"rows": rows});
      expect(c.headers["Authorization"], "Bearer $_session");
      expect(c.queryParameters, isEmpty, reason: "no on_conflict: the function resolves conflicts");
    });

    test("an empty batch sends nothing", () async {
      final r = _Recorder();
      await _gw(r, session: _session).upsertHistory(<Map<String, dynamic>>[]);
      expect(r.calls, isEmpty);
    });
  });
}
