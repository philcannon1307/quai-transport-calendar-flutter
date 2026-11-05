import "package:dio/dio.dart";

/// One item line of a sales order (NetSuite item sublist), as served by the exchange server.
class SalesOrderItem {
  const SalesOrderItem({required this.name, this.sku = "", this.quantity, this.unit = "", this.memo = ""});

  final String name;
  final String sku;
  final num? quantity;
  final String unit;
  final String memo;

  static String _s(dynamic v) => v == null ? "" : v.toString();

  factory SalesOrderItem.fromJson(Map<String, dynamic> j) => SalesOrderItem(
        name: _s(j["name"]),
        sku: _s(j["sku"]),
        quantity: j["quantity"] is num ? j["quantity"] as num : num.tryParse(_s(j["quantity"])),
        unit: _s(j["unit"]),
        memo: _s(j["memo"]),
      );
}

/// What the exchange server knows about a sales order that has NO truck yet
/// (GET /middleware/sales-order?id=...). [items] is null until the middleware serves item lines.
class SalesOrderDetails {
  const SalesOrderDetails({
    required this.salesOrderId,
    required this.soNum,
    this.customer = "",
    this.status = "",
    this.orderDate = "",
    this.shipDate = "",
    this.promiseDate = "",
    this.location = "",
    this.shippingMethod = "",
    this.address = "",
    this.city = "",
    this.phone = "",
    this.eventName = "",
    this.service = "",
    this.memo = "",
    this.items,
  });

  final String salesOrderId;
  final String soNum;
  final String customer;
  final String status;
  final String orderDate;
  final String shipDate;
  final String promiseDate;
  final String location;
  final String shippingMethod;
  final String address;
  final String city;
  final String phone;
  final String eventName;
  final String service;
  final String memo;
  final List<SalesOrderItem>? items;

  bool get itemsAvailable => items != null;

  static String _s(dynamic v) => v == null ? "" : v.toString();

  factory SalesOrderDetails.fromJson(Map<String, dynamic> j) {
    final raw = j["items"];
    return SalesOrderDetails(
      salesOrderId: _s(j["salesOrderId"]),
      soNum: _s(j["soNum"]),
      customer: _s(j["customer"]),
      status: _s(j["status"]),
      orderDate: _s(j["orderDate"]),
      shipDate: _s(j["shipDate"]),
      promiseDate: _s(j["promiseDate"]),
      location: _s(j["location"]),
      shippingMethod: _s(j["shippingMethod"]),
      address: _s(j["address"]),
      city: _s(j["city"]),
      phone: _s(j["phone"]),
      eventName: _s(j["eventName"]),
      service: _s(j["service"]),
      memo: _s(j["memo"]),
      items: raw is List
          ? raw.whereType<Map>().map((e) => SalesOrderItem.fromJson(e.cast<String, dynamic>())).toList()
          : null,
    );
  }
}

/// Proxy URL for the sales-order route, derived from the Pick-ups proxy URL (same server).
String salesOrderUrlFor(String proxyUrl) {
  final u = proxyUrl.trim();
  if (u.isEmpty) return "";
  if (u.endsWith("/middleware/events")) return "${u.substring(0, u.length - "/events".length)}/sales-order";
  var base = u;
  while (base.endsWith("/")) {
    base = base.substring(0, base.length - 1);
  }
  return "$base/middleware/sales-order";
}

/// Reads the provisional picking-list data. Never throws: null when the order cannot be read.
class SalesOrderService {
  SalesOrderService({required this.url, required this.token, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 40),
              validateStatus: (_) => true,
            ));

  final String url;
  final String? Function() token;
  final Dio _dio;

  Future<SalesOrderDetails?> fetch(int salesOrderId) async {
    if (url.isEmpty || salesOrderId <= 0) return null;
    try {
      final t = token();
      final res = await _dio.get<dynamic>(
        url,
        queryParameters: <String, dynamic>{"id": salesOrderId.toString(), "_": DateTime.now().millisecondsSinceEpoch},
        options: Options(headers: <String, String>{
          if (t != null && t.isNotEmpty) "Authorization": "Bearer $t",
          "Cache-Control": "no-store",
        }),
      );
      final data = res.data;
      if (res.statusCode != 200 || data is! Map) return null;
      return SalesOrderDetails.fromJson(data.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }
}
