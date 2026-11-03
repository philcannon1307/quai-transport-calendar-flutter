import "dart:typed_data";

import "package:dio/dio.dart";

import "../logic/announcements.dart";
import "backend_gateway.dart";

/// Supabase over plain HTTP (PostgREST, Storage, Edge Functions) using dio —
/// no SDK, so no extra native or plugin dependencies.
///
/// SECURITY NOTE: [anonKey] is Supabase's PUBLISHABLE key. Its power is whatever
/// the row-level-security policies grant, and in the reference project those
/// policies let ANYONE insert/update/delete announcements, order photos and
/// delivery history ("Anyone can ..." policies). Until they are tightened (or
/// these writes move behind a server-side function), the key is effectively a
/// write credential for those tables. The app therefore never ships it by
/// default: it must be supplied at build time.
class SupabaseRestGateway implements BackendGateway {
  SupabaseRestGateway({required String baseUrl, required this.anonKey, Dio? dio})
      : baseUrl = baseUrl.replaceAll(RegExp(r"/+$"), ""),
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
              sendTimeout: const Duration(seconds: 60),
            ));

  final String baseUrl;
  final String anonKey;
  final Dio _dio;

  @override
  bool get configured => baseUrl.isNotEmpty && anonKey.isNotEmpty;

  Map<String, String> _headers([Map<String, String>? extra]) => <String, String>{
        "apikey": anonKey,
        "Authorization": "Bearer $anonKey",
        ...?extra,
      };

  static String _message(dynamic data) {
    if (data is Map) {
      final m = data["message"] ?? data["error"] ?? data["msg"] ?? data["hint"];
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
          headers: auth ? _headers(headers) : <String, String>{"apikey": anonKey, ...?headers},
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

  static const Map<String, String> _jsonReturn = <String, String>{
    "Content-Type": "application/json",
    "Prefer": "return=representation",
  };

  String _rest(String table) => "$baseUrl/rest/v1/$table";

  List<Map<String, dynamic>> _rows(dynamic data) =>
      data is List ? data.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : <Map<String, dynamic>>[];

  // --- announcements ---------------------------------------------------------

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
    final res = await _send("POST", _rest("announcements"), data: row, headers: _jsonReturn);
    final rows = _rows(res.data);
    if (rows.isEmpty) throw const BackendException(0, "announcement was not created");
    return rows.first["id"].toString();
  }

  @override
  Future<void> updateAnnouncement(String id, Map<String, String> row) async {
    await _send(
      "PATCH",
      _rest("announcements"),
      query: <String, dynamic>{"id": "eq.$id"},
      data: <String, dynamic>{...row, "updated_at": DateTime.now().toUtc().toIso8601String()},
      headers: const <String, String>{"Content-Type": "application/json"},
    );
  }

  @override
  Future<void> deleteAnnouncement(String id) async {
    await _send("DELETE", _rest("announcements"), query: <String, dynamic>{"id": "eq.$id"});
  }

  @override
  Future<void> insertAnnouncementImage(String announcementId, String url) async {
    await _send(
      "POST",
      _rest("announcement_images"),
      data: <String, String>{"announcement_id": announcementId, "storage_url": url},
      headers: const <String, String>{"Content-Type": "application/json"},
    );
  }

  @override
  Future<void> deleteAnnouncementImageByUrl(String url) async {
    await _send("DELETE", _rest("announcement_images"), query: <String, dynamic>{"storage_url": "eq.$url"});
  }

  // --- storage ---------------------------------------------------------------

  static String _encodePath(String path) => path.split("/").map(Uri.encodeComponent).join("/");

  @override
  String publicUrl(String bucket, String path) => "$baseUrl/storage/v1/object/public/$bucket/${_encodePath(path)}";

  @override
  Future<String> uploadFile({
    required String bucket,
    required String path,
    required Uint8List bytes,
    required String contentType,
  }) async {
    await _send(
      "POST",
      "$baseUrl/storage/v1/object/$bucket/${_encodePath(path)}",
      data: Stream<List<int>>.value(bytes),
      headers: <String, String>{
        "Content-Type": contentType,
        Headers.contentLengthHeader: bytes.length.toString(),
        "x-upsert": "false",
      },
    );
    return publicUrl(bucket, path);
  }

  @override
  Future<void> removeFiles(String bucket, List<String> paths) async {
    if (paths.isEmpty) return;
    await _send(
      "DELETE",
      "$baseUrl/storage/v1/object/$bucket",
      data: <String, dynamic>{"prefixes": paths},
      headers: const <String, String>{"Content-Type": "application/json"},
    );
  }

  // --- receipts and change reports ------------------------------------------------

  @override
  Future<String?> insertReceipt(Map<String, dynamic> row) async {
    final res = await _send("POST", _rest("receipts"), data: row, headers: _jsonReturn);
    final rows = _rows(res.data);
    return rows.isEmpty ? null : rows.first["id"]?.toString();
  }

  @override
  Future<void> markReceiptEmailSent(String id) => _markSent("receipts", id);

  @override
  Future<void> insertAdjustment(Map<String, dynamic> row) async {
    await _send(
      "POST",
      _rest("order_adjustments"),
      data: row,
      headers: const <String, String>{"Content-Type": "application/json", "Prefer": "return=minimal"},
    );
  }

  @override
  Future<void> markAdjustmentEmailSent(String id) => _markSent("order_adjustments", id);

  Future<void> _markSent(String table, String id) async {
    await _send(
      "PATCH",
      _rest(table),
      query: <String, dynamic>{"id": "eq.$id"},
      data: const <String, dynamic>{"email_sent": true},
      headers: const <String, String>{"Content-Type": "application/json", "Prefer": "return=minimal"},
    );
  }

  @override
  Future<EmailOutcome> sendEmail({
    required String template,
    String? recipient,
    required String idempotencyKey,
    required Map<String, dynamic> data,
  }) async {
    final res = await _send(
      "POST",
      "$baseUrl/functions/v1/send-transactional-email",
      data: <String, dynamic>{
        "templateName": template,
        if (recipient != null) "recipientEmail": recipient,
        "idempotencyKey": idempotencyKey,
        "templateData": data,
      },
      headers: const <String, String>{"Content-Type": "application/json"},
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
    await _send(
      "POST",
      _rest("delivery_history"),
      query: const <String, dynamic>{"on_conflict": "so_num"},
      data: rows,
      headers: const <String, String>{
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates,return=minimal",
      },
    );
  }

  @override
  Future<List<Map<String, dynamic>>> historyRows({
    required String from,
    required String to,
    List<String>? carrierNames,
    List<int>? carrierIds,
  }) async {
    final query = <String, dynamic>{
      "select": "*",
      "and": "(ship_date.gte.$from,ship_date.lt.$to)",
      "order": "ship_date.desc",
      "limit": "2000",
    };
    if (carrierIds != null && carrierIds.isNotEmpty) {
      query["carrier_id"] = "in.(${carrierIds.join(",")})";
    } else if (carrierNames != null && carrierNames.isNotEmpty) {
      query["carrier_name"] = "in.(${carrierNames.map((n) => '"${n.replaceAll('"', "")}"').join(",")})";
    }
    return _rows((await _send("GET", _rest("delivery_history"), query: query)).data);
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
