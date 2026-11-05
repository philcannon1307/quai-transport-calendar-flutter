import "package:dio/dio.dart";

import "../logic/order_change.dart";
import "../models/order.dart";
import "backend_gateway.dart";

/// One HTTP call to the data API ("/orders/..."). Real one = dio; tests use a fake.
abstract class OrderChangeTransport {
  bool get configured;
  Future<Map<String, dynamic>> send(String method, String path, {Object? body, Map<String, String>? query});
}

class UnconfiguredOrderChangeTransport implements OrderChangeTransport {
  const UnconfiguredOrderChangeTransport();
  @override
  bool get configured => false;
  @override
  Future<Map<String, dynamic>> send(String method, String path, {Object? body, Map<String, String>? query}) =>
      Future<Map<String, dynamic>>.error(const BackendNotConfigured());
}

class DioOrderChangeTransport implements OrderChangeTransport {
  DioOrderChangeTransport({required String baseUrl, required this.sessionToken, Dio? dio})
      : baseUrl = baseUrl.replaceAll(RegExp(r"/+$"), ""),
        _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(seconds: 30)));

  final String baseUrl;
  final String? Function() sessionToken;
  final Dio _dio;

  @override
  bool get configured => baseUrl.isNotEmpty;

  @override
  Future<Map<String, dynamic>> send(String method, String path, {Object? body, Map<String, String>? query}) async {
    final jwt = sessionToken();
    if (jwt == null || jwt.isEmpty) throw const BackendException(401, "not_signed_in");
    try {
      final res = await _dio.request<dynamic>(
        "$baseUrl$path",
        data: body,
        queryParameters: query,
        options: Options(
          method: method,
          headers: <String, String>{"X-Quai-Session": jwt, "Content-Type": "application/json"},
          responseType: ResponseType.json,
          validateStatus: (_) => true,
        ),
      );
      final status = res.statusCode ?? 0;
      final d = res.data;
      if (status >= 400) throw BackendException(status, d is Map ? (d["error"] ?? "").toString() : "");
      return d is Map ? d.cast<String, dynamic>() : <String, dynamic>{};
    } on DioException catch (e) {
      throw BackendException(e.response?.statusCode ?? 0, e.message ?? "network error");
    }
  }
}

/// Order change notice: preview who is told, save the change, read history and "changed" markers.
class OrderChangeService {
  OrderChangeService({required this.transport});
  final OrderChangeTransport transport;

  bool get configured => transport.configured;

  static String _path(String num, [String tail = ""]) => "/orders/" + Uri.encodeComponent(num.trim().toUpperCase()) + "/changes" + tail;

  Future<PreviewResult> preview(Order order) async {
    final j = await transport.send("POST", _path(order.soNum, "/preview"), body: <String, dynamic>{"context": orderContext(order)});
    return PreviewResult.fromJson(j);
  }

  Future<SubmitResult> submit(Order order, List<FieldChange> changes, {String reason = ""}) async {
    final j = await transport.send("POST", _path(order.soNum), body: <String, dynamic>{
      "changes": changes.map((c) => c.toJson()).toList(),
      "reason": reason.trim(),
      "context": orderContext(order),
    });
    return SubmitResult.fromJson(j);
  }

  Future<List<ChangeGroup>> history(String orderNum) async {
    final j = await transport.send("GET", _path(orderNum));
    final list = j["changes"];
    if (list is! List) return <ChangeGroup>[];
    return list.whereType<Map>().map((e) => ChangeGroup.fromJson(e.cast<String, dynamic>())).toList();
  }

  /// Which of [orderNums] carry saved changes (drives the "Modifié / Changed" badge).
  Future<Map<String, ChangedInfo>> changed(List<String> orderNums) async {
    final nums = orderNums.map((n) => n.trim().toUpperCase()).where((n) => n.isNotEmpty).toSet().take(300).toList();
    if (nums.isEmpty) return <String, ChangedInfo>{};
    final j = await transport.send("GET", "/orders/changed", query: <String, String>{"nums": nums.join(",")});
    final m = j["changed"];
    final out = <String, ChangedInfo>{};
    if (m is Map) {
      m.forEach((k, v) {
        if (v is Map) {
          out[k.toString().toUpperCase()] = ChangedInfo(
            count: v["count"] is num ? (v["count"] as num).toInt() : 1,
            lastBy: (v["lastBy"] ?? "").toString(),
            lastAt: (v["lastAt"] ?? "").toString(),
          );
        }
      });
    }
    return out;
  }
}

/// Plain-words reason for a failed call (FR / EN pair is chosen by the caller).
String changeErrorKey(Object e) {
  if (e is BackendNotConfigured) return "not_configured";
  if (e is BackendException) {
    if (e.status == 401) return "session";
    if (e.status == 403) return "forbidden";
    if (e.status == 429) return "too_many";
    if (e.status == 422 || e.status == 400) return "invalid";
    if (e.status == 0) return "network";
  }
  return "error";
}
