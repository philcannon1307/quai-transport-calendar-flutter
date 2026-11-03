import "../models/order.dart";

/// The server rejected the token (401/403): the session or a linked truck's
/// token is stale. The client cannot re-login by itself (credentials live
/// server-side), so callers surface this and ask the user to sign in again.
class UnauthorizedException implements Exception {
  const UnauthorizedException();
  @override
  String toString() => "Session expirée.";
}

class OrdersFetchException implements Exception {
  const OrdersFetchException(this.status);
  final int? status;
  @override
  String toString() => "Orders fetch failed (${status ?? "network"})";
}

/// What the repository needs from the job service. ApiClient implements it;
/// tests use fakes.
abstract class OrdersApi {
  /// Sales-order jobs for the token's truck. Throws [UnauthorizedException]
  /// on 401/403 and [OrdersFetchException] on any other failure.
  Future<List<Order>> shipOrders(String token, {String? carrierName});

  /// Transfer orders (Gooseneck trucks). Never throws: [] on failure.
  Future<List<Order>> transferOrders(String token, {String? carrierName});
}
