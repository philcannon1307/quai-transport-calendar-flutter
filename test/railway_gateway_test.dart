import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/supabase_rest_gateway.dart";

/// The Railway data API keeps the Supabase-shaped paths, so the same gateway talks to it with NO public key.
class _Rec implements HttpClientAdapter {
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

void main() {
  const base = "https://soothing-creativity-production-e925.up.railway.app";

  test("configured with only a URL (no public key)", () {
    final gw = SupabaseRestGateway(baseUrl: base + "/", anonKey: "", dio: Dio()..httpClientAdapter = _Rec());
    expect(gw.configured, isTrue);
    expect(SupabaseRestGateway(baseUrl: "", anonKey: "").configured, isFalse);
  });

  test("no apikey / Authorization header is sent without a key; paths stay Supabase-shaped", () async {
    final rec = _Rec();
    final gw = SupabaseRestGateway(baseUrl: base, anonKey: "", sessionToken: () => "SESSION", dio: Dio()..httpClientAdapter = rec);
    await gw.activeAnnouncements();
    expect(rec.calls.single.uri.toString().startsWith(base + "/rest/v1/announcements"), isTrue);
    expect(rec.calls.single.headers.containsKey("apikey"), isFalse);
    expect(rec.calls.single.headers.containsKey("Authorization"), isFalse);
    await gw.historyRows(from: "2026-01-01", to: "2026-02-01");
    expect(rec.calls.last.uri.toString(), base + "/functions/v1/quai-data");
    expect(rec.calls.last.headers["X-Quai-Session"], "SESSION");
    expect(gw.publicUrl("receipts", "2026-11-04/a b.png"), base + "/storage/v1/object/public/receipts/2026-11-04/a%20b.png");
  });
}
