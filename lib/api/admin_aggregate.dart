import "package:dio/dio.dart";

import "../data/carriers.dart";
import "../models/order.dart";
import "orders_repository.dart";

/// One truck in the server-side aggregate (GET /admin/orders-aggregate).
class AggregateTruck {
  const AggregateTruck({
    required this.name,
    required this.displayName,
    required this.status,
    this.lastRefreshedAt,
    this.ship = const <Map<String, dynamic>>[],
    this.transfer = const <Map<String, dynamic>>[],
  });

  /// Backend username (e.g. "RIDEAU GOOSENECK").
  final String name;

  /// Calendar name the app groups it under (e.g. "InterQL").
  final String displayName;

  /// ok | stale | failed | pending
  final String status;
  final DateTime? lastRefreshedAt;
  final List<Map<String, dynamic>> ship;
  final List<Map<String, dynamic>> transfer;

  bool get hasData => lastRefreshedAt != null;

  static List<Map<String, dynamic>> _rows(dynamic v) =>
      v is List ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : <Map<String, dynamic>>[];

  factory AggregateTruck.fromJson(Map<String, dynamic> j) {
    final orders = j["orders"] is Map ? (j["orders"] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final name = (j["name"] ?? "").toString();
    return AggregateTruck(
      name: name,
      displayName: (j["displayName"] ?? name).toString(),
      status: (j["status"] ?? "failed").toString(),
      lastRefreshedAt: DateTime.tryParse((j["lastRefreshedAt"] ?? "").toString()),
      ship: _rows(orders["ship"]),
      transfer: _rows(orders["transfer"]),
    );
  }
}

/// The exchange server's cached view of every truck's orders.
class AdminAggregate {
  const AdminAggregate({this.generatedAt, this.refreshing = false, this.trucks = const <AggregateTruck>[]});

  /// Time of the freshest truck refresh; null before the first one.
  final DateTime? generatedAt;

  /// The server is refreshing right now.
  final bool refreshing;
  final List<AggregateTruck> trucks;

  /// At least one truck has data (even stale data beats the slow per-truck path).
  bool get hasData => trucks.any((t) => t.hasData);

  factory AdminAggregate.fromJson(Map<String, dynamic> j) => AdminAggregate(
        generatedAt: DateTime.tryParse((j["generatedAt"] ?? "").toString()),
        refreshing: j["refreshing"] == true,
        trucks: j["trucks"] is List
            ? (j["trucks"] as List).whereType<Map>().map((e) => AggregateTruck.fromJson(e.cast<String, dynamic>())).toList()
            : const <AggregateTruck>[],
      );

  /// Same result shape as OrdersRepository.loadAggregate, built from the server's rows.
  /// Trucks with no data at all are listed as not loaded; a stale truck keeps its last orders.
  OrdersLoad toOrdersLoad() {
    final merged = <Order>[];
    final seen = <String>{};
    final failed = <String>[];
    for (final t in trucks) {
      if (!t.hasData) {
        failed.add(t.name);
        continue;
      }
      final name = calendarName(t.displayName);
      final orders = <Order>[
        ...t.ship.map((j) => Order.fromShipCalendar(j, carrierName: name)),
        ...t.transfer.where((j) => !Order.isShell(j)).map((j) => Order.fromTransfer(j, carrierName: name)),
      ];
      for (final o in orders.map((o) => o.withCarrierName(name))) {
        if (seen.add(OrdersRepository.orderKey(o))) merged.add(o);
      }
    }
    return OrdersLoad(orders: merged, failedTrucks: failed);
  }
}

/// How the server answered a refresh request.
enum AggregateRefresh { started, alreadyRunning, rateLimited, failed }

/// Proxy URL for the aggregate, derived from the Pick-ups proxy URL (same server).
String adminAggregateUrlFor(String proxyUrl) {
  var u = proxyUrl.trim();
  if (u.isEmpty) return "";
  if (u.endsWith("/middleware/events")) u = u.substring(0, u.length - "/middleware/events".length);
  while (u.endsWith("/")) {
    u = u.substring(0, u.length - 1);
  }
  return "$u/admin/orders-aggregate";
}

/// Reads the cached aggregate. Never throws: null when the server cannot answer
/// (the Admin screen then falls back to loading truck by truck).
class AdminAggregateService {
  AdminAggregateService({required this.url, required this.token, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              validateStatus: (_) => true,
            ));

  final String url;
  final String? Function() token;
  final Dio _dio;

  Options get _options {
    final t = token();
    return Options(headers: <String, String>{
      if (t != null && t.isNotEmpty) "Authorization": "Bearer $t",
      "Cache-Control": "no-store",
    });
  }

  Future<AdminAggregate?> fetch() async {
    if (url.isEmpty) return null;
    try {
      final res = await _dio.get<dynamic>(url, queryParameters: <String, dynamic>{"_": DateTime.now().millisecondsSinceEpoch}, options: _options);
      final data = res.data;
      if (res.statusCode != 200 || data is! Map) return null;
      return AdminAggregate.fromJson(data.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// Asks the server to refresh now (the server rate-limits this).
  Future<AggregateRefresh> requestRefresh() async {
    if (url.isEmpty) return AggregateRefresh.failed;
    try {
      final res = await _dio.post<dynamic>("$url/refresh", options: _options);
      final data = res.data;
      if (res.statusCode == 202) {
        return data is Map && data["started"] == false ? AggregateRefresh.alreadyRunning : AggregateRefresh.started;
      }
      if (res.statusCode == 429) return AggregateRefresh.rateLimited;
      return AggregateRefresh.failed;
    } catch (_) {
      return AggregateRefresh.failed;
    }
  }
}
