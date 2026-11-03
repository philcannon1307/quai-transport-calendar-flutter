import "../models/order.dart";

/// One calendar event from the after-sales middleware (Ste-Agathe source).
class MiddlewareEvent {
  const MiddlewareEvent({
    required this.id,
    required this.title,
    required this.salesOrderId,
    required this.startDate,
    this.location,
    this.status,
    this.customer,
    this.soStatus,
  });

  final String id;
  final String title;
  final String salesOrderId;
  final String startDate;
  final String? location;
  final String? status;
  final String? customer;
  final String? soStatus;

  static String? _s(dynamic v) => v?.toString();

  factory MiddlewareEvent.fromJson(Map<String, dynamic> j) => MiddlewareEvent(
        id: _s(j["id"]) ?? "",
        title: _s(j["title"]) ?? "",
        salesOrderId: _s(j["salesOrderId"]) ?? "",
        startDate: _s(j["startDate"]) ?? "",
        location: _s(j["location"]),
        status: _s(j["status"]),
        customer: _s(j["customer"]),
        soStatus: _s(j["soStatus"]),
      );
}

/// Event title -> unified Order card. Ported from mapMiddlewareEvent in api.ts.
/// The SO number is parsed out of the title; the LAST "/"-segment decides
/// pick-up vs delivery/installation. Returns null when the title carries no SO.
Order? mapMiddlewareEvent(MiddlewareEvent e) {
  final match = RegExp(r"SO\d+", caseSensitive: false).firstMatch(e.title);
  if (match == null) return null;
  final soNum = match.group(0)!.toUpperCase();
  final segments = e.title.split("/").map((s) => s.trim()).toList();
  final lastSeg = segments.isEmpty ? "" : segments.last;
  final isPickup = RegExp(r"ramassage|pick-?up|cueillette", caseSensitive: false).hasMatch(lastSeg);
  final fallbackCustomer = segments.length > 2 ? segments[2] : "";
  final customer = (e.customer != null && e.customer!.isNotEmpty) ? e.customer : fallbackCustomer;
  final firstSeg = segments.isNotEmpty ? segments.first : "";
  return Order(
    kind: OrderKind.order,
    soNum: soNum,
    soId: int.tryParse(e.salesOrderId) ?? 0,
    customer: customer,
    serviceType: isPickup ? "Pick-up" : "Livraison & Installation",
    status: (e.soStatus ?? "").replaceFirst(RegExp(r"^Sales Order\s*:\s*", caseSensitive: false), ""),
    eventStatus: e.status ?? "",
    shipDate: e.startDate,
    date: e.startDate,
    eventStartDate: e.startDate,
    city: firstSeg.isNotEmpty ? firstSeg : e.location,
    shippingLocationName: e.location,
    serviceEventId: int.tryParse(e.id),
  );
}
