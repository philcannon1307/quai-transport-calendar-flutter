enum OrderKind { order, transfer }

/// Unified calendar card: a sales order or a transfer order.
class Order {
  const Order({
    required this.kind,
    required this.soNum,
    required this.date,
    this.soId,
    this.customer,
    this.serviceTypeId,
    this.serviceType,
    this.status,
    this.eventStatus,
    this.shipDate,
    this.city,
    this.state,
    this.shippingLocationId,
    this.shippingLocationName,
    this.saleLocationId,
    this.saleLocationName,
    this.eventStartDate,
    this.truckId,
    this.truckName,
    this.serviceEventId,
    this.serviceEventName,
    this.memo,
    this.carrierName,
    this.middlewareLocation,
  });

  final OrderKind kind;
  final String soNum;
  final int? soId;
  final String? customer;
  final int? serviceTypeId;
  final String? serviceType;
  final String? status;
  final String? eventStatus;
  final String? shipDate;
  final String? city;
  final String? state;
  final int? shippingLocationId;
  final String? shippingLocationName;
  final int? saleLocationId;
  final String? saleLocationName;
  final String? eventStartDate;
  final String date;
  final int? truckId;
  final String? truckName;
  final int? serviceEventId;
  final String? serviceEventName;
  final String? memo;
  final String? carrierName;

  /// Calendar location of a middleware event (Logistique only); shown on the card.
  final String? middlewareLocation;

  bool get isTransfer => kind == OrderKind.transfer;

  /// Same card, tagged with the calendar it belongs to.
  Order withCarrierName(String? name) => Order(
        kind: kind,
        soNum: soNum,
        date: date,
        soId: soId,
        customer: customer,
        serviceTypeId: serviceTypeId,
        serviceType: serviceType,
        status: status,
        eventStatus: eventStatus,
        shipDate: shipDate,
        city: city,
        state: state,
        shippingLocationId: shippingLocationId,
        shippingLocationName: shippingLocationName,
        saleLocationId: saleLocationId,
        saleLocationName: saleLocationName,
        eventStartDate: eventStartDate,
        truckId: truckId,
        truckName: truckName,
        serviceEventId: serviceEventId,
        serviceEventName: serviceEventName,
        memo: memo,
        carrierName: name,
        middlewareLocation: middlewareLocation,
      );

  static String? _s(dynamic v) => v == null ? null : v.toString();
  static int? _i(dynamic v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse(v?.toString() ?? ""));

  /// Sales order from /api/ship-calendar/orders.
  factory Order.fromShipCalendar(Map<String, dynamic> j,
          {String? carrierName}) =>
      Order(
        kind: OrderKind.order,
        soNum: _s(j["soNum"]) ?? "",
        soId: _i(j["soId"]),
        customer: _s(j["customer"]),
        serviceTypeId: _i(j["serviceTypeId"]),
        serviceType: _s(j["serviceType"]),
        status: _s(j["status"]),
        eventStatus: _s(j["eventStatus"]),
        shipDate: _s(j["shipDate"]),
        city: _s(j["city"]),
        state: _s(j["state"]),
        shippingLocationId: _i(j["shippingLocationId"]),
        shippingLocationName: _s(j["shippingLocationName"]),
        saleLocationId: _i(j["saleLocationId"]),
        saleLocationName: _s(j["saleLocationName"]),
        eventStartDate: _s(j["eventStartDate"]),
        date: _s(j["date"]) ?? _s(j["shipDate"]) ?? "",
        truckId: _i(j["truckId"]),
        truckName: _s(j["truckName"]),
        serviceEventId: _i(j["serviceEventId"]),
        serviceEventName: _s(j["serviceEventName"]),
        memo: _s(j["memo"]),
        carrierName: carrierName,
      );

  /// Transfer order from /api/transfer-calendar/orders. Mirrors the React mapping.
  factory Order.fromTransfer(Map<String, dynamic> j, {String? carrierName}) {
    final from = _s(j["fromLocationName"]) ?? "?";
    final to = _s(j["toLocationName"]) ?? "?";
    final raw = _s(j["status"]) ?? "";
    return Order(
      kind: OrderKind.transfer,
      soNum: _s(j["toNum"]) ?? "",
      soId: _i(j["toId"]),
      customer: "$from → $to",
      serviceTypeId: null,
      serviceType: "Transfert / Transfer",
      status: raw.replaceFirst(
          RegExp(r"^Transfer Order\s*:\s*", caseSensitive: false), ""),
      eventStatus: _s(j["eventStatus"]) ?? "",
      shipDate: _s(j["date"]),
      city: _s(j["toLocationName"]),
      state: null,
      shippingLocationId: _i(j["fromLocationId"]),
      shippingLocationName: _s(j["fromLocationName"]),
      saleLocationId: _i(j["toLocationId"]),
      saleLocationName: _s(j["toLocationName"]),
      eventStartDate: _s(j["eventStartDate"]),
      date: _s(j["date"]) ?? "",
      truckId: _i(j["truckId"]),
      truckName: _s(j["truck"]),
      serviceEventId: _i(j["serviceEventId"]),
      memo: _s(j["memo"]),
      carrierName: carrierName,
    );
  }

  static bool isShell(Map<String, dynamic> j) => j["isShell"] == true;
}

/// TO numbers look like TO12345.
bool isTransferNum(String? num) =>
    RegExp(r"^TO\d+$", caseSensitive: false).hasMatch((num ?? "").trim());
