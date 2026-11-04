import "dart:convert";
import "dart:typed_data";

import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:quai_calendar/api/backend_gateway.dart";
import "package:quai_calendar/api/supabase_rest_gateway.dart";

/// Records every request; answers with [status] and [body].
class _Recorder implements HttpClientAdapter {
  _Recorder({this.status = 200, this.body = '{"ok":true}'});
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

const _anon = "ANON-PUBLIC-KEY";
const _session = "SESSION.JWT.VALUE";
const _fn = "https://p.supabase.test/functions/v1/quai-data";

SupabaseRestGateway _gw(_Recorder r, {String? session}) => SupabaseRestGateway(
      baseUrl: "https://p.supabase.test/",
      anonKey: _anon,
      sessionToken: () => session,
      dio: Dio()..httpClientAdapter = r,
    );

Map<String, dynamic> _json(RequestOptions c) =>
    jsonDecode(jsonEncode(c.data)) as Map<String, dynamic>;

void main() {
  group("who is who on the wire", () {
    test(
        "every write goes to quai-data: Authorization = PUBLIC key, session only in X-Quai-Session",
        () async {
      final r = _Recorder();
      await _gw(r, session: _session)
          .insertAdjustment(<String, dynamic>{"id": "x"});
      final c = r.calls.single;
      expect(c.method, "POST");
      expect(c.path, _fn);
      expect(c.headers["Authorization"], "Bearer $_anon");
      expect(c.headers["apikey"], _anon);
      expect(c.headers["X-Quai-Session"], _session);
      expect(_json(c), <String, dynamic>{
        "op": "adjustment.insert",
        "row": <String, dynamic>{"id": "x"}
      });
    });

    test("signed out: no write leaves the device (401 without a request)",
        () async {
      final r = _Recorder();
      final g = _gw(r);
      await expectLater(
          g.insertAdjustment(<String, dynamic>{"id": "x"}),
          throwsA(
              isA<BackendException>().having((e) => e.status, "status", 401)));
      await expectLater(
          g.deleteAnnouncement("a"), throwsA(isA<BackendException>()));
      await expectLater(
          g.upsertHistory(<Map<String, dynamic>>[
            <String, dynamic>{"so_num": "1"}
          ]),
          throwsA(isA<BackendException>()));
      await expectLater(
          g.uploadFile(
              bucket: "receipts",
              path: "2026-11-03/a.jpg",
              bytes: Uint8List.fromList(<int>[1]),
              contentType: "image/jpeg"),
          throwsA(isA<BackendException>()));
      await expectLater(
          g.sendEmail(
              template: "t", idempotencyKey: "k", data: <String, dynamic>{}),
          throwsA(isA<BackendException>()));
      expect(r.calls, isEmpty);
    });

    test("reads of announcements use the public key only (no session)",
        () async {
      final r = _Recorder(body: "[]");
      await _gw(r, session: _session).activeAnnouncements();
      final c = r.calls.single;
      expect(c.path, "https://p.supabase.test/rest/v1/announcements");
      expect(c.headers["Authorization"], "Bearer $_anon");
      expect(c.headers.containsKey("X-Quai-Session"), isFalse);
    });

    test("the session is never sent to a PostgREST or storage URL", () async {
      final r = _Recorder();
      final g = _gw(r, session: _session);
      await g.insertAnnouncement(
          <String, String>{"title": "t", "body": "b"}).catchError((_) => "");
      await g.removeFiles("announcement-images", <String>["a/1-x.jpg"]);
      await g.upsertHistory(<Map<String, dynamic>>[
        <String, dynamic>{"so_num": "1"}
      ]);
      for (final c in r.calls) {
        expect(c.path, startsWith("https://p.supabase.test/functions/v1/"),
            reason: c.path);
        expect(c.path, isNot(contains("/rest/v1/")));
        expect(c.path, isNot(contains("/storage/v1/")));
      }
    });
  });

  group("the operations", () {
    test("announcements", () async {
      final r = _Recorder(body: '{"ok":true,"id":"abc"}');
      final g = _gw(r, session: _session);
      expect(
          await g
              .insertAnnouncement(<String, String>{"title": "t", "body": "b"}),
          "abc");
      await g.updateAnnouncement("abc", <String, String>{"title": "n"});
      await g.deleteAnnouncement("abc");
      await g.insertAnnouncementImage("abc", "https://u/x.jpg");
      await g.deleteAnnouncementImageByUrl("https://u/x.jpg");
      expect(r.calls.map((c) => _json(c)["op"]), <String>[
        "announcement.insert",
        "announcement.update",
        "announcement.delete",
        "announcement.image.add",
        "announcement.image.remove",
      ]);
      expect(_json(r.calls[1]), <String, dynamic>{
        "op": "announcement.update",
        "id": "abc",
        "row": <String, dynamic>{"title": "n"}
      });
    });

    test("an insert that returns no id is an error", () async {
      await expectLater(
          _gw(_Recorder(), session: _session)
              .insertAnnouncement(<String, String>{"title": "t", "body": "b"}),
          throwsA(isA<BackendException>()));
    });

    test(
        "upload: raw bytes + query, the function's folder rules decide; returns the public URL",
        () async {
      final r = _Recorder();
      final url = await _gw(r, session: _session).uploadFile(
          bucket: "receipts",
          path: "bol/2026-11-03/a b.jpg",
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
          contentType: "image/jpeg");
      final c = r.calls.single;
      expect(c.path, _fn);
      expect(c.queryParameters, <String, dynamic>{
        "op": "upload",
        "bucket": "receipts",
        "path": "bol/2026-11-03/a b.jpg"
      });
      expect(c.headers["Content-Type"], "image/jpeg");
      expect(c.headers["X-Quai-Session"], _session);
      expect(c.headers["Authorization"], "Bearer $_anon");
      expect(url,
          "https://p.supabase.test/storage/v1/object/public/receipts/bol/2026-11-03/a%20b.jpg");
    });

    test(
        "receipts: id back; marking as emailed is the server's job (no request)",
        () async {
      final r = _Recorder(body: '{"ok":true,"id":"rid"}');
      final g = _gw(r, session: _session);
      expect(await g.insertReceipt(<String, dynamic>{"driver_name": "Bob"}),
          "rid");
      await g.markReceiptEmailSent("rid");
      await g.markAdjustmentEmailSent("aid");
      expect(r.calls, hasLength(1));
      expect(_json(r.calls.single)["op"], "receipt.insert");
    });

    test(
        "the email call: session in X-Quai-Session, public key as bearer, no recipient",
        () async {
      final r = _Recorder();
      await _gw(r, session: _session).sendEmail(
          template: "order-adjustment",
          idempotencyKey: "k",
          data: <String, dynamic>{"reportId": "r"});
      final c = r.calls.single;
      expect(c.path,
          "https://p.supabase.test/functions/v1/send-transactional-email");
      expect(c.headers["Authorization"], "Bearer $_anon");
      expect(c.headers["X-Quai-Session"], _session);
      expect(c.data, <String, dynamic>{
        "templateName": "order-adjustment",
        "idempotencyKey": "k",
        "templateData": <String, dynamic>{"reportId": "r"}
      });
    });

    test("suppressed email is reported, not an error", () async {
      final r =
          _Recorder(body: '{"success":false,"reason":"email_suppressed"}');
      expect(
          await _gw(r, session: _session).sendEmail(
              template: "t", idempotencyKey: "k", data: <String, dynamic>{}),
          EmailOutcome.suppressed);
    });
  });

  group("delivery history", () {
    test("snapshot -> history.upsert {rows}", () async {
      final r = _Recorder();
      final rows = <Map<String, dynamic>>[
        <String, dynamic>{"so_num": "SO1", "carrier_name": "Gat - Sam"}
      ];
      await _gw(r, session: _session).upsertHistory(rows);
      expect(_json(r.calls.single),
          <String, dynamic>{"op": "history.upsert", "rows": rows});
    });

    test("an empty batch sends nothing", () async {
      final r = _Recorder();
      await _gw(r, session: _session).upsertHistory(<Map<String, dynamic>>[]);
      expect(r.calls, isEmpty);
    });

    test("reading: range + optional filters; rows come back", () async {
      final r = _Recorder(body: '{"ok":true,"rows":[{"so_num":"SO1"}]}');
      final rows = await _gw(r, session: _session).historyRows(
          from: "2026-11-01", to: "2026-12-01", carrierIds: <int>[64]);
      expect(rows, <Map<String, dynamic>>[
        <String, dynamic>{"so_num": "SO1"}
      ]);
      expect(_json(r.calls.single), <String, dynamic>{
        "op": "history.list",
        "from": "2026-11-01",
        "to": "2026-12-01",
        "carrierIds": <int>[64]
      });
    });
  });

  group("errors", () {
    test("the function's error code becomes the message; 409 keeps its status",
        () async {
      final r = _Recorder(status: 409, body: '{"error":"already_exists"}');
      await expectLater(
        _gw(r, session: _session)
            .insertAdjustment(<String, dynamic>{"id": "x"}),
        throwsA(isA<BackendException>()
            .having((e) => e.status, "status", 409)
            .having((e) => e.message, "message", "already_exists")),
      );
    });

    test(
        "401/403 from the function surface as BackendException with that status",
        () async {
      for (final s in <int>[401, 403]) {
        await expectLater(
          _gw(_Recorder(status: s, body: '{"error":"invalid_session"}'),
                  session: _session)
              .deleteAnnouncement("a"),
          throwsA(isA<BackendException>().having((e) => e.status, "status", s)),
        );
      }
    });
  });
}
