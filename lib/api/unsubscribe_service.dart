import "backend_gateway.dart";

/// Token from `/unsubscribe?token=...`. Flutter web with hash routing sees it
/// either on the page URL (`...?token=x#/unsubscribe`) or inside the hash route
/// (`#/unsubscribe?token=x`); accept both.
String? unsubscribeToken({required String routeName, required Uri pageUri}) {
  final inRoute = Uri.tryParse(routeName)?.queryParameters["token"];
  final raw = (inRoute != null && inRoute.isNotEmpty) ? inRoute : pageUri.queryParameters["token"];
  if (raw == null) return null;
  final t = raw.trim();
  return t.isEmpty ? null : t;
}

class UnsubscribeService {
  UnsubscribeService({required this.gateway});
  final BackendGateway gateway;

  Future<UnsubscribeCheck> check(String? token) async {
    if (token == null || !gateway.configured) return UnsubscribeCheck.invalid;
    try {
      return await gateway.checkUnsubscribe(token);
    } on BackendException {
      return UnsubscribeCheck.invalid;
    }
  }

  Future<UnsubscribeResult> confirm(String token) async {
    try {
      return await gateway.confirmUnsubscribe(token);
    } on BackendException {
      return UnsubscribeResult.error;
    }
  }
}
