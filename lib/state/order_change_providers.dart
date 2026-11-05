import "package:flutter_riverpod/flutter_riverpod.dart";

import "../api/order_change_service.dart";
import "../logic/order_change.dart";
import "../models/order.dart";
import "providers.dart";

final orderChangeTransportProvider = Provider<OrderChangeTransport>((ref) {
  final url = ref.watch(backendUrlProvider);
  if (url.isEmpty) return const UnconfiguredOrderChangeTransport();
  return DioOrderChangeTransport(baseUrl: url, sessionToken: () => ref.read(sessionProvider).sessionToken());
});

final orderChangeServiceProvider = Provider<OrderChangeService>((ref) => OrderChangeService(transport: ref.watch(orderChangeTransportProvider)));

/// History of one order (newest first). Errors (offline, not configured) simply mean "nothing to show".
final orderChangesProvider = FutureProvider.family<List<ChangeGroup>, String>((ref, orderNum) {
  return ref.watch(orderChangeServiceProvider).history(orderNum);
});

/// Which of the orders currently on screen carry changes. Never breaks the calendar: errors -> no badges.
final changedOrdersProvider = FutureProvider<Map<String, ChangedInfo>>((ref) async {
  final service = ref.watch(orderChangeServiceProvider);
  if (!service.configured) return <String, ChangedInfo>{};
  final mine = ref.watch(ordersProvider).valueOrNull ?? const <Order>[];
  final admin = ref.watch(adminLoadProvider).valueOrNull?.orders ?? const <Order>[];
  final nums = <String>[...mine.map((o) => o.soNum), ...admin.map((o) => o.soNum)];
  return service.changed(nums);
});
