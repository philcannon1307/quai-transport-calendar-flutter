import "../data/carriers.dart";
import "../models/order.dart";

class LocationRef {
  const LocationRef(this.id, this.name);
  final int id;
  final String name;
}

/// calendar name -> carrier group (SADM, Gatineau, Gooseneck, ...).
Map<String, String> carrierGroupMap() => <String, String>{for (final c in kCarriers) c.displayName: c.group};

/// Distinct groups in roster order.
List<String> allGroups() {
  final seen = <String>{};
  return <String>[for (final c in kCarriers) if (seen.add(c.group)) c.group];
}

/// Orders per group (orders from a carrier with no group are not counted).
Map<String, int> groupCounts(List<Order> orders) {
  final map = carrierGroupMap();
  final out = <String, int>{};
  for (final o in orders) {
    final g = o.carrierName == null ? null : map[o.carrierName];
    if (g == null) continue;
    out[g] = (out[g] ?? 0) + 1;
  }
  return out;
}

List<Order> filterByGroup(List<Order> orders, String? group) {
  if (group == null) return orders;
  final map = carrierGroupMap();
  return orders.where((o) => o.carrierName != null && map[o.carrierName] == group).toList();
}

/// Orders per shipping location id (orders with no location are not counted).
Map<int, int> locationCounts(List<Order> orders) {
  final out = <int, int>{};
  for (final o in orders) {
    final id = o.shippingLocationId;
    if (id == null) continue;
    out[id] = (out[id] ?? 0) + 1;
  }
  return out;
}

/// Locations that appear in [orders]. The reference fetched the full list from
/// the API but only ever DISPLAYED locations with at least one order (or the
/// selected one), so deriving them from the orders is equivalent.
List<LocationRef> locationsOf(List<Order> orders) {
  final seen = <int, String>{};
  for (final o in orders) {
    final id = o.shippingLocationId;
    final name = o.shippingLocationName;
    if (id == null || name == null || name.isEmpty) continue;
    seen.putIfAbsent(id, () => name);
  }
  return <LocationRef>[for (final e in seen.entries) LocationRef(e.key, e.value)];
}

List<Order> filterByLocation(List<Order> orders, int? locationId) {
  if (locationId == null) return orders;
  return orders.where((o) => o.shippingLocationId == locationId).toList();
}

/// Pills to show: those with orders (or currently selected), busiest first.
List<T> visibleSorted<T>(List<T> items, int Function(T) count, bool Function(T) isSelected) {
  final shown = items.where((i) => count(i) > 0 || isSelected(i)).toList();
  shown.sort((a, b) => count(b).compareTo(count(a)));
  return shown;
}
