import "dart:typed_data";

import "package:dio/dio.dart";

import "../logic/announcements.dart";
import "backend_gateway.dart";

/// Supabase over plain HTTP using dio — no SDK, so no extra native or plugin dependencies.
///
/// WHO MAY DO WHAT. The public (anon) key in [anonKey] can only READ the announcements: the
/// database is locked so that it grants no write at all (supabase-lockdown.sql). Every write, file
/// upload, private read and email goes through two edge functions that check the exchange
/// server's session token (sent as X-Quai-Session) and then act with the service role:
///   * quai-data                 announcements, files, receipts, change reports, delivery history
///   * send-transactional-email  emails (recipients are computed there, never by this client)
/// The Authorization bearer is always the public key, which Supabase's gateway accepts; the
/// session token is never sent anywhere else.
class SupabaseRestGateway implements BackendGateway {
  SupabaseRestGateway({required String baseUrl, required this.anonKey, this.sessionToken, Dio? dio})
      : baseUrl = baseUrl.replaceAll(RegExp(r"/+$"), ""),
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
              sendTimeout: const Duration(seconds: 60),
            ));

  final String baseUrl;
  final String anonKey;

  /// Returns the exchange-issued session JWT (null when signed out).
  final String? Function()? sessionToken;
  final Dio _dio;

  @override
  bool get configured => baseUrl.isNotEmpty && anonKey.isNotEmpty;

  /// Public headers: identify the project; read-only power.
  Map<String, String> _publicHeaders([Map<String, String>? extra]) => <String, String>{
        "apikey": anonKey,
        "Authorization": "Bearer " + anonKey,
        ...?extra,
      };

  String _session() {
    final jwt = sessionToken?.call();
    if (jwt == null || jwt.isEmpty) throw const BackendException(401, "not_signed_in");
    return jwt;
  }

  static String _message(dynamic data) {
    if (data is Map) {
      final m = data["error"] ?? data["message"] ?? data["msg"] ?? data["hint"];
      if (m != null) return m.toString();
    }
    return data?.toString() ?? "";
  }

  Future<Response<dynamic>> _send(
    String method,
    String url, {
    Object? data,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    bool auth = true,
  }) async {
    try {
      final res = await _dio.request<dynamic>(
        url,
        data: data,
        queryParameters: query,
        options: Options(
          method: method,
          headers: auth ? _publicHeaders(headers) : <String, String>{"apikey": anonKey, ...?headers},
          responseType: ResponseType.json,
          validateStatus: (_) => true,
        ),
      );
      final status = res.statusCode ?? 0;
      if (status >= 400) throw BackendException(status, _message(res.data));
      return res;
    } on DioException catch (e) {
      throw BackendException(e.response?.statusCode ?? 0, e.message ?? "network error");
    }
  }

  /// One call to the quai-data function: `{op, ...args}` -> the JSON answer.
  Future<Map<String, dynamic>> _op(String op, [Map<String, dynamic> args = const <String, dynamic>{}]) async {
    final res = await _send(
      "POST",
      "$baseUrl/functions/v1/quai-data",
      data: <String, dynamic>{"op": op, ...args},
      headers: <String, String>{"Content-Type": "application/json", "X-Quai-Session": _session()},
    );
    final d = res.data;
    return d is Map ? d.cast<String, dynamic>() : <String, dynamic>{};
  }

  String _rest(String table) => "$baseUrl/rest/v1/$table";

  List<Map<String, dynamic>> _rows(dynamic data) =>
      data is List ? data.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : <Map<String, dynamic>>[];

  // --- announcements ---------------------------------------------------------

  /// Public read: the lockdown leaves exactly this (active announcements and their photos).
  @override
  Future<List<Announcement>> activeAnnouncements() async {
    final posts = _rows((await _send("GET", _rest("announcements"), query: <String, dynamic>{
      "select": "*",
      "is_active": "eq.true",
      "order": "created_at.desc",
    }))
        .data);
    if (posts.isEmpty) return <Announcement>[];
    // One query for every photo instead of one per announcement.
    final ids = posts.map((p) => p["id"].toString()).join(",");
    final imgs = _rows((await _send("GET", _rest("announcement_images"), query: <String, dynamic>{
      "select": "announcement_id,storage_url",
      "announcement_id": "in.($ids)",
      "order": "created_at.asc",
    }))
        .data);
    final byPost = <String, List<String>>{};
    for (final i in imgs) {
      byPost.putIfAbsent(i["announcement_id"].toString(), () => <String>[]).add(i["storage_url"].toString());
    }
    return posts.map((p) => Announcement.fromRow(p, images: byPost[p["id"].toString()] ?? const <String>[])).toList();
  }

  @override
  Future<String> insertAnnouncement(Map<String, String> row) async {
    final id = (await _op("announcement.insert", <String, dynamic>{"row": row}))["id"];
    if (id == null) throw const BackendException(0, "announcement was not created");
    return id.toString();
  }

  @override
  Future<void> updateAnnouncement(String id, Map<String, String> row) async {
    await _op("announcement.update", <String, dynamic>{"id": id, "row": row});
  }

  @override
  Future<void> deleteAnnouncement(String id) async {
    await _op("announcement.delete", <String, dynamic>{"id": id});
  }

  @override
  Future<void> insertAnnouncementImage(String announcementId, String url) async {
    await _op("announcement.image.add", <String, dynamic>{"announcementId": announcementId, "url": url});
  }

  @override
  Future<void> deleteAnnouncementImageByUrl(String url) async {
    await _op("announcement.image.remove", <String, dynamic>{"url": url});
  }

  // --- storage ---------------------------------------------------------------

  static String _encodePath(String path) => path.split("/").map(Uri.encodeComponent).join("/");

  @override
  String publicUrl(String bucket, String path) => "$baseUrl/storage/v1/object/public/$bucket/${_encodePath(path)}";

  /// The bytes go to the function (which checks who you are, the folder, the picture type and
  /// size) and it stores them; no direct storage access exists for the public key.
  @override
  Future<String> uploadFile({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
  }) async {
    await _send(
      "POST",
      "$baseUrl/functions/v1/quai-data",
      query: <String, dynamic>{"op": "upload", "bucket": bucket, "path": path},
      data: Stream<List<int>>.value(bytes),
      headers: <String, String>{
        "Content-Type": contentType,
        Headers.contentLengthHeader: bytes.length.toString(),
        "X-Quai-Session": _session(),
      },
    );
    return publicUrl(bucket, path);
  }

  @override
  Future<void> removeFiles(String bucket, List<String> paths) async {
    if (paths.isEmpty) return;
    await _op("files.remove", <String, dynamic>{"bucket": bucket, "paths": paths});
  }

  // --- receipts and change reports ------------------------------------------------
  // carrier_name and email_sent in these rows are ignored by the server: it uses the signed-in
  // carrier from the session token and marks rows as emailed itself.

  @override
  Future<String?> insertReceipt(Map<String, dynamic> row) async =>
      (await _op("receipt.insert", <String, dynamic>{"row": row}))["id"]?.toString();

  @override
  Future<void> markReceiptEmailSent(String id) async {} // done by send-transactional-email

  @override
  Future<void> insertAdjustment(Map<String, dynamic> row) async {
    await _op("adjustment.insert", <String, dynamic>{"row": row});
  }

  @override
  Future<void> markAdjustmentEmailSent(String id) async {} // done by send-transactional-email

  @override
  Future<EmailOutcome> sendEmail({
    required String template,
    required String idempotencyKey,
    required Map<String, dynamic> data,
  }) async {
    final res = await _send(
      "POST",
      "$baseUrl/functions/v1/send-transactional-email",
      data: <String, dynamic>{
        "templateName": template,
        "idempotencyKey": idempotencyKey,
        "templateData": data,
      },
      headers: <String, String>{"Content-Type": "application/json", "X-Quai-Session": _session()},
    );
    final body = res.data;
    if (body is Map && body["success"] == false && body["reason"] == "email_suppressed") {
      return EmailOutcome.suppressed;
    }
    return EmailOutcome.sent;
  }

  // --- delivery history ---------------------------------------------------------

  @override
  Future<void> upsertHistory(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    await _op("history.upsert", <String, dynamic>{"rows": rows});
  }

  @override
  Future<List<Map<String, dynamic>>> historyRows({
    required String from,
    required String to,
    List<String>? carrierNames,
    List<int>? carrierIds,
  }) async {
    final res = await _op("history.list", <String, dynamic>{
      "from": from,
      "to": to,
      if (carrierNames != null && carrierNames.isNotEmpty) "carrierNames": carrierNames,
      if (carrierIds != null && carrierIds.isNotEmpty) "carrierIds": carrierIds,
    });
    return _rows(res["rows"]);
  }

  // --- unsubscribe --------------------------------------------------------------

  @override
  Future<UnsubscribeCheck> checkUnsubscribe(String token) async {
    try {
      final res = await _send(
        "GET",
        "$baseUrl/functions/v1/handle-email-unsubscribe",
        query: <String, dynamic>{"token": token},
        auth: false,
      );
      final data = res.data;
      if (data is Map) {
        if (data["valid"] == false && data["reason"] == "already_unsubscribed") {
          return UnsubscribeCheck.alreadyUnsubscribed;
        }
        if (data["valid"] == true) return UnsubscribeCheck.valid;
      }
      return UnsubscribeCheck.invalid;
    } on BackendException {
      return UnsubscribeCheck.invalid;
    }
  }

  @override
  Future<UnsubscribeResult> confirmUnsubscribe(String token) async {
    try {
      final res = await _send(
        "POST",
        "$baseUrl/functions/v1/handle-email-unsubscribe",
        data: <String, String>{"token": token},
        headers: const <String, String>{"Content-Type": "application/json"},
      );
      final data = res.data;
      if (data is Map) {
        if (data["success"] == true) return UnsubscribeResult.done;
        if (data["reason"] == "already_unsubscribed") return UnsubscribeResult.alreadyUnsubscribed;
      }
      return UnsubscribeResult.error;
    } on BackendException {
      return UnsubscribeResult.error;
    }
  }
}
