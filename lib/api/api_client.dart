import "package:dio/dio.dart";
import "package:flutter/foundation.dart" show visibleForTesting;
import "../models/order.dart";
import "orders_api.dart";
import "ticket_service.dart";

/// Quai backend API client.
///
/// Mirrors the reference app's transport rules exactly:
///  - Bearer token per truck
///  - cache: no-store AND a ?_=<timestamp> cache-buster on every read
///  - picking ticket works only with the OWNING truck's token; a 404 is retried once
class ApiClient implements OrdersApi {
  ApiClient({Dio? dio, this.baseUrl = kJobServiceBaseUrl})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
            ));

  static const String kJobServiceBaseUrl = "https://quai-contractor-calendar-production.up.railway.app";

  final Dio _dio;
  final String baseUrl;

  Map<String, String> _headers(String token) => <String, String>{
        "Authorization": "Bearer $token",
        "Cache-Control": "no-store",
        "Pragma": "no-cache",
      };

  /// Appends the cache-buster the backend requires: ?_=<epoch-millis>
  /// (or &_= when the path already carries a query).
  ///
  /// NOTE: written as ${sep} deliberately. "$sep_=" parses as the identifier
  /// `sep_` in Dart and fails to compile — it did, once.
  @visibleForTesting
  static String cacheBustedUrl(String baseUrl, String path, int millis) {
    final sep = path.contains("?") ? "&" : "?";
    return "$baseUrl$path${sep}_=$millis";
  }

  String _bust(String path) => cacheBustedUrl(baseUrl, path, DateTime.now().millisecondsSinceEpoch);

  /// Sales-order jobs for the token's truck. Returns [] on a network/server failure
  /// (reference behaviour: one bad truck cannot blank the calendar) BUT a 401/403
  /// throws [UnauthorizedException] so an expired session is never shown as an
  /// empty calendar.
  Future<List<Order>> fetchShipCalendarOrders(String token, {String? carrierName}) async {
    try {
      final res = await _dio.getUri<dynamic>(Uri.parse(_bust("/api/ship-calendar/orders")),
          options: Options(headers: _headers(token), responseType: ResponseType.json));
      final rows = _rows(res.data, "orders");
      return rows.map((j) => Order.fromShipCalendar(j, carrierName: carrierName)).toList();
    } on DioException catch (e) {
      final s = e.response?.statusCode;
      if (s == 401 || s == 403) throw const UnauthorizedException();
      return <Order>[];
    } catch (_) {
      return <Order>[];
    }
  }

  Future<List<String>> fetchShipCalendarLocations(String token) async {
    try {
      final res = await _dio.getUri<dynamic>(Uri.parse(_bust("/api/ship-calendar/locations")),
          options: Options(headers: _headers(token), responseType: ResponseType.json));
      final data = res.data;
      final list = data is Map ? (data["locations"] ?? data["data"]) : data;
      if (list is List) {
        return list
            .map((e) => e is Map ? (e["name"] ?? e["locationName"] ?? "").toString() : e.toString())
            .where((s) => s.isNotEmpty)
            .toList();
      }
      return <String>[];
    } catch (_) {
      return <String>[];
    }
  }

  /// Transfer orders (Gooseneck trucks 3 + 4). Shell rows are discarded.
  Future<List<Order>> fetchTransferOrders(String token, {String? carrierName}) async {
    try {
      final res = await _dio.getUri<dynamic>(Uri.parse(_bust("/api/transfer-calendar/orders")),
          options: Options(headers: _headers(token), responseType: ResponseType.json));
      return _rows(res.data, "orders")
          .where((j) => !Order.isShell(j))
          .map((j) => Order.fromTransfer(j, carrierName: carrierName))
          .toList();
    } catch (_) {
      return <Order>[];
    }
  }

  /// Picking-ticket PDF bytes. Owning-truck token only; retries ONCE on 404.
  Future<List<int>?> fetchPickingTicket({required String token, required String num}) async {
    final isTransfer = isTransferNum(num);
    final path = isTransfer ? "/api/transfer-calendar/picking-ticket/$num" : "/api/ship-calendar/picking-ticket/$num";
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final res = await _dio.getUri<List<int>>(Uri.parse(_bust(path)),
            options: Options(headers: _headers(token), responseType: ResponseType.bytes, validateStatus: (s) => s != null && s < 500));
        if (res.statusCode == 200 && res.data != null) return res.data;
        if (res.statusCode == 404 && attempt == 0) continue; // documented: retry once
        return null;
      } on DioException catch (e) {
        if (e.response?.statusCode == 404 && attempt == 0) continue;
        return null;
      }
    }
    return null;
  }

  @override
  Future<List<Order>> shipOrders(String token, {String? carrierName}) async {
    try {
      final res = await _dio.getUri<dynamic>(Uri.parse(_bust("/api/ship-calendar/orders")),
          options: Options(headers: _headers(token), responseType: ResponseType.json));
      return _rows(res.data, "orders").map((j) => Order.fromShipCalendar(j, carrierName: carrierName)).toList();
    } on DioException catch (e) {
      final s = e.response?.statusCode;
      if (s == 401 || s == 403) throw const UnauthorizedException();
      throw OrdersFetchException(s);
    }
  }

  @override
  Future<List<Order>> transferOrders(String token, {String? carrierName}) =>
      fetchTransferOrders(token, carrierName: carrierName);

  /// One raw picking-ticket request: no retry, no fallback (TicketService owns
  /// those rules). A null token sends no Authorization header, as in the reference.
  Future<TicketHttpResult> fetchTicketRaw(
    String? token,
    String ticketNum, {
    void Function(double? fraction)? onDownload,
  }) async {
    final encoded = Uri.encodeComponent(ticketNum);
    final path = isTransferNum(ticketNum)
        ? "/api/transfer-calendar/picking-ticket/$encoded"
        : "/api/ship-calendar/picking-ticket/$encoded";
    try {
      final res = await _dio.getUri<List<int>>(
        Uri.parse(_bust(path)),
        options: Options(
          headers: token == null
              ? <String, String>{"Cache-Control": "no-store", "Pragma": "no-cache"}
              : _headers(token),
          responseType: ResponseType.bytes,
          validateStatus: (s) => s != null && s < 500,
        ),
        onReceiveProgress: onDownload == null
            ? null
            : (received, total) => onDownload(total > 0 ? received / total : null),
      );
      return TicketHttpResult(res.statusCode ?? 0, res.data);
    } on DioException catch (e) {
      return TicketHttpResult(e.response?.statusCode ?? 0);
    }
  }

  static List<Map<String, dynamic>> _rows(dynamic data, String key) {
    final raw = data is Map ? data[key] : data;
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }
}
