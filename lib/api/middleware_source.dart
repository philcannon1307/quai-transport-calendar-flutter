import "package:dio/dio.dart";

import "../logic/middleware_events.dart";

/// Source of Ste-Agathe calendar events (the only place pick-ups come from).
///
/// SECURITY: the reference app shipped the middleware's x-api-key in the web
/// bundle. This port never holds it. The key lives on a server-side proxy that
/// accepts the user's access token; this class only calls the proxy.
///
/// PROXY (built into the exchange server, server/src/middleware.js):
///   GET <exchange base>/middleware/events?location=Ste-Agathe&from=YYYY-MM-DD&to=YYYY-MM-DD
///   Authorization: Bearer <SESSION JWT>   (role logistique or superuser)
///   -> the middleware's JSON, unchanged: { "events": [MiddlewareEvent...] }
/// The proxy adds x-api-key and forwards to /api/netsuite/events.
///
/// CONFIG: nothing extra to set. The proxy lives on the same server as the sign-in, so its URL
/// is derived from QUAI_EXCHANGE_URL ([middlewareProxyUrlFor]). QUAI_MIDDLEWARE_PROXY_URL
/// remains as an optional override.
/// Where the proxy lives: the explicit override when given, else the exchange URL
/// (`https://host/exchange` or `https://host`) with the proxy path. "" when neither is set.
String middlewareProxyUrlFor({required String exchangeUrl, String override = ""}) {
  final o = override.trim();
  if (o.isNotEmpty) return o;
  var base = exchangeUrl.trim();
  if (base.isEmpty) return "";
  while (base.endsWith("/")) {
    base = base.substring(0, base.length - 1);
  }
  if (base.endsWith("/exchange")) base = base.substring(0, base.length - "/exchange".length);
  return "$base/middleware/events";
}

abstract class MiddlewareSource {
  /// False when no proxy is configured; the UI then says pick-ups are unavailable
  /// instead of silently showing an empty Pick-ups tab.
  bool get configured;

  /// Never throws: [] on any failure, like the reference.
  Future<List<MiddlewareEvent>> events(String location, {required DateTime from, required DateTime to});
}

class UnconfiguredMiddlewareSource implements MiddlewareSource {
  const UnconfiguredMiddlewareSource();

  @override
  bool get configured => false;

  @override
  Future<List<MiddlewareEvent>> events(String location, {required DateTime from, required DateTime to}) async =>
      <MiddlewareEvent>[];
}

class ProxyMiddlewareSource implements MiddlewareSource {
  ProxyMiddlewareSource({required this.proxyUrl, required this.token, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
            ));

  final String proxyUrl;
  final String? Function() token;
  final Dio _dio;

  @override
  bool get configured => proxyUrl.isNotEmpty;

  static String _fmt(DateTime d) => d.toIso8601String().substring(0, 10);

  @override
  Future<List<MiddlewareEvent>> events(String location, {required DateTime from, required DateTime to}) async {
    try {
      final t = token();
      final res = await _dio.get<dynamic>(
        proxyUrl,
        queryParameters: <String, dynamic>{
          "location": location,
          "from": _fmt(from),
          "to": _fmt(to),
          "_": DateTime.now().millisecondsSinceEpoch,
        },
        options: Options(headers: <String, String>{
          if (t != null && t.isNotEmpty) "Authorization": "Bearer $t",
          "Cache-Control": "no-store",
        }),
      );
      final data = res.data;
      final list = data is Map ? data["events"] : (data is List ? data : null);
      if (list is! List) return <MiddlewareEvent>[];
      return list.whereType<Map>().map((e) => MiddlewareEvent.fromJson(e.cast<String, dynamic>())).toList();
    } catch (_) {
      return <MiddlewareEvent>[];
    }
  }
}
