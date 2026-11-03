import "../models/order.dart";
import "../logic/delivery_history.dart";
import "backend_gateway.dart";

/// Delivery history: every refresh mirrors the live orders into
/// `delivery_history`, so a job stays visible after NetSuite closes it.
class HistoryService {
  HistoryService({required this.gateway, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final BackendGateway gateway;
  final DateTime Function() _clock;

  /// Best-effort and silent: history must never break the calendar.
  /// Returns true when a batch was written.
  Future<bool> snapshot(List<Order> orders, {int? carrierId}) async {
    if (!gateway.configured) return false;
    final rows = historyRows(orders, carrierId: carrierId);
    if (rows.isEmpty) return false;
    try {
      await gateway.upsertHistory(rows);
      return true;
    } on BackendException {
      return false;
    }
  }

  /// Past deliveries (today excluded) for [days] back. Empty on any failure.
  Future<List<Order>> past({
    required int days,
    List<String>? carrierNames,
    List<int>? carrierIds,
  }) async {
    if (days <= 0 || !gateway.configured) return <Order>[];
    final window = historyWindow(days, _clock());
    try {
      final rows = await gateway.historyRows(
        from: window.from,
        to: window.to,
        carrierNames: carrierNames,
        carrierIds: carrierIds,
      );
      return rows.map(orderFromHistoryRow).toList();
    } on BackendException {
      return <Order>[];
    }
  }
}
