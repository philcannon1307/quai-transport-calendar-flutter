import "../logic/prep_state.dart";
import "order_change_service.dart";

/// Shared "prepared" state: GET /prep-state (a date window) and PUT /prep-state/:order.
/// Uses the same transport as the order-change feature (session header, base URL, errors).
class PrepStateService {
  PrepStateService({required this.transport});
  final OrderChangeTransport transport;

  bool get configured => transport.configured;

  /// Prepared orders with a service date in [from]..[to] (both "YYYY-MM-DD").
  Future<Map<String, PrepEntry>> fetch(String from, String to) async {
    final j = await transport.send("GET", "/prep-state", query: <String, String>{"from": from, "to": to});
    return parsePrepStates(j);
  }

  /// Sets the state; idempotent on the server. Only logistics logins and the SuperUser are allowed (403 otherwise).
  Future<PrepEntry> set(String orderNum, String date, bool prepared, {String label = ""}) async {
    final j = await transport.send(
      "PUT",
      "/prep-state/" + Uri.encodeComponent(orderNum.trim().toUpperCase()),
      body: <String, dynamic>{"prepared": prepared, "date": date, if (label.isNotEmpty) "label": label},
    );
    return PrepEntry.fromJson(j);
  }
}
