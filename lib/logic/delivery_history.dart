import "../data/carriers.dart";
import "../models/carrier.dart";
import "../models/order.dart";
import "ids.dart";

/// Row for delivery_history, mirroring snapshotOrders() in the reference.
Map<String, dynamic> historyRow(Order o, {int? carrierId}) => <String, dynamic>{
      "so_num": o.soNum,
      "so_id": o.soId,
      "customer": o.customer,
      "service_type": o.serviceType,
      "service_type_id": o.serviceTypeId,
      "status": o.status,
      "event_status": o.eventStatus,
      "ship_date": o.shipDate,
      "event_start_date": o.eventStartDate,
      "city": o.city,
      "state": o.state,
      "shipping_location_id": o.shippingLocationId,
      "shipping_location_name": o.shippingLocationName,
      "sale_location_id": o.saleLocationId,
      "sale_location_name": o.saleLocationName,
      "truck_id": o.truckId,
      "truck_name": o.truckName,
      "service_event_id": o.serviceEventId,
      "service_event_name": o.serviceEventName,
      "carrier_id": carrierId,
      "carrier_name": o.carrierName,
      "source": "app",
    };

/// One upsert batch, de-duplicated by so_num (first one wins).
///
/// REFERENCE BUG FIXED: delivery_history is keyed on so_num, and two linked
/// trucks (InterQL 3+4) can share one sales order. Postgres rejects an upsert
/// that touches the same key twice in a single statement ("ON CONFLICT DO
/// UPDATE command cannot affect row a second time"), so the reference silently
/// lost the WHOLE snapshot for those carriers. Orders without a number are
/// skipped.
List<Map<String, dynamic>> historyRows(List<Order> orders, {int? carrierId}) {
  final seen = <String>{};
  final rows = <Map<String, dynamic>>[];
  for (final o in orders) {
    if (o.soNum.isEmpty || !seen.add(o.soNum)) continue;
    rows.add(historyRow(o, carrierId: carrierId));
  }
  return rows;
}

Order orderFromHistoryRow(Map<String, dynamic> r) {
  String? s(dynamic v) => v?.toString();
  int? i(dynamic v) => v is int ? v : (v is num ? v.toInt() : int.tryParse(v?.toString() ?? ""));
  final transfer = RegExp(r"^TO\d+$", caseSensitive: false).hasMatch(s(r["so_num"]) ?? "");
  return Order(
    kind: transfer ? OrderKind.transfer : OrderKind.order,
    soNum: s(r["so_num"]) ?? "",
    soId: i(r["so_id"]),
    customer: s(r["customer"]) ?? "",
    serviceTypeId: i(r["service_type_id"]),
    serviceType: s(r["service_type"]),
    status: s(r["status"]) ?? "",
    eventStatus: s(r["event_status"]) ?? "",
    shipDate: s(r["ship_date"]) ?? "",
    eventStartDate: s(r["event_start_date"]) ?? "",
    date: s(r["ship_date"]) ?? "",
    city: s(r["city"]),
    state: s(r["state"]),
    shippingLocationId: i(r["shipping_location_id"]),
    shippingLocationName: s(r["shipping_location_name"]),
    saleLocationId: i(r["sale_location_id"]),
    saleLocationName: s(r["sale_location_name"]),
    truckId: i(r["truck_id"]),
    truckName: s(r["truck_name"]),
    serviceEventId: i(r["service_event_id"]),
    serviceEventName: s(r["service_event_name"]),
    carrierName: s(r["carrier_name"]),
  );
}

/// History covers [days] back from today, TODAY EXCLUDED (today is live data):
/// from <= ship_date < to. Local calendar dates (the reference used UTC, which
/// is off by a day for a Toronto user after 7 pm).
({String from, String to}) historyWindow(int days, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  return (from: isoDate(today.subtract(Duration(days: days))), to: isoDate(today));
}

/// Live orders win over history for the same sales order; history-only rows
/// come first. Dedupe is by soNum, as in the reference.
List<Order> mergeLiveAndPast(List<Order> live, List<Order> past) {
  if (past.isEmpty) return live;
  final liveNums = live.map((o) => o.soNum).toSet();
  final onlyPast = past.where((o) => !liveNums.contains(o.soNum)).toList();
  return <Order>[...onlyPast, ...live];
}

/// Carrier names to filter history by for a signed-in (non-super) user: the
/// calendar name, the backend account name and every linked truck.
List<String> historyCarrierNames(Carrier? carrier, String carrierName) {
  final names = <String>{carrierName};
  if (carrier != null) {
    names.add(carrier.displayName);
    names.add(carrier.backendUsername ?? carrier.displayName);
    for (final t in carrier.linkedTrucks) {
      names.add(t.displayName);
    }
  }
  names.removeWhere((n) => n.isEmpty);
  return names.toList();
}

/// "Historique" ranges offered in the UI; 0 = live only.
const List<int> kHistoryRanges = <int>[0, 7, 30, 365];

// kCarriers import kept for callers that resolve a carrier by name.
Carrier? carrierFor(String name) => carrierByDisplayName(name);
