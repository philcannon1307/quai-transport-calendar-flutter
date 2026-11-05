import "../models/order.dart";

/// One editable field of an order / picking ticket (keys match the server's allow-list).
class ChangeField {
  const ChangeField(this.key, this.fr, this.en, {this.transferOnly = false, this.orderOnly = false});
  final String key;
  final String fr;
  final String en;
  final bool transferOnly;
  final bool orderOnly;
}

const List<ChangeField> kChangeFields = <ChangeField>[
  ChangeField("ship_date", "Date d'expédition", "Ship date"),
  ChangeField("truck", "Camion", "Truck"),
  ChangeField("carrier", "Transporteur", "Carrier"),
  ChangeField("customer", "Client", "Customer", orderOnly: true),
  ChangeField("address", "Adresse", "Address"),
  ChangeField("phone", "Téléphone", "Phone"),
  ChangeField("city", "Ville", "City"),
  ChangeField("shipping_location", "Lieu d'expédition", "Shipping location"),
  ChangeField("receiving_location", "Lieu de réception", "Receiving location", transferOnly: true),
  ChangeField("service_type", "Type de service", "Service type", orderOnly: true),
  ChangeField("status_note", "Statut", "Status"),
  ChangeField("memo", "Mémo", "Memo"),
];

/// The fields shown for [order] (transfer-only / order-only ones are filtered).
List<ChangeField> fieldsFor(Order order) =>
    kChangeFields.where((f) => order.isTransfer ? !f.orderOnly : !f.transferOnly).toList();

/// What the ticket shows today, per field key. Unknown values are empty strings.
Map<String, String> currentValues(Order o) => <String, String>{
      "ship_date": o.shipDate ?? o.date,
      "truck": o.truckName ?? "",
      "carrier": o.carrierName ?? "",
      "customer": o.customer ?? "",
      "address": "",
      "phone": "",
      "city": o.city ?? "",
      "shipping_location": o.shippingLocationName ?? "",
      "receiving_location": o.saleLocationName ?? "",
      "service_type": o.serviceType ?? "",
      "status_note": o.status ?? "",
      "memo": o.memo ?? "",
    };

/// Where the order leaves from / goes to: the server resolves the divisions from these.
Map<String, String> orderContext(Order o) => <String, String>{
      if ((o.shippingLocationName ?? "").isNotEmpty) "shippingLocationName": o.shippingLocationName!,
      if (o.isTransfer && (o.saleLocationName ?? "").isNotEmpty) "saleLocationName": o.saleLocationName!,
      if ((o.carrierName ?? o.truckName ?? "").isNotEmpty) "carrierName": (o.carrierName ?? o.truckName)!,
      if (!o.isTransfer && (o.customer ?? "").isNotEmpty) "customer": o.customer!,
    };

class FieldChange {
  const FieldChange({required this.field, required this.oldValue, required this.newValue});
  final String field;
  final String oldValue;
  final String newValue;

  Map<String, String> toJson() => <String, String>{"field": field, "old": oldValue, "new": newValue};

  factory FieldChange.fromJson(Map<String, dynamic> j) => FieldChange(
        field: (j["field"] ?? "").toString(),
        oldValue: (j["old"] ?? "").toString(),
        newValue: (j["new"] ?? "").toString(),
      );

  /// Human label, FR or EN. "item:2x4" -> "Article : 2x4".
  String label({required bool french}) {
    for (final f in kChangeFields) {
      if (f.key == field) return french ? f.fr : f.en;
    }
    final i = field.indexOf(":");
    if (i > 0) {
      final kind = field.substring(0, i);
      final rest = field.substring(i + 1);
      return kind == "item" ? (french ? "Article : " : "Item: ") + rest : rest;
    }
    return field;
  }
}

/// A quantity line edited by the user (item, planned -> actual).
class ItemEdit {
  const ItemEdit({this.item = "", this.from = "", this.to = ""});
  final String item;
  final String from;
  final String to;
}

/// Fields whose trimmed text differs from the original, plus the edited item lines.
List<FieldChange> diffChanges(Map<String, String> before, Map<String, String> after, {List<ItemEdit> items = const <ItemEdit>[]}) {
  final out = <FieldChange>[];
  after.forEach((key, value) {
    final o = (before[key] ?? "").trim();
    final n = value.trim();
    if (o != n) out.add(FieldChange(field: key, oldValue: o, newValue: n));
  });
  final seen = <String>{};
  for (final it in items) {
    final name = it.item.trim();
    final from = it.from.trim();
    final to = it.to.trim();
    if (name.isEmpty || from == to || name.length > 70 || !seen.add(name)) continue;
    out.add(FieldChange(field: "item:$name", oldValue: from, newValue: to));
  }
  return out;
}

class PreviewRecipient {
  const PreviewRecipient({required this.email, required this.roles, this.division});
  final String email;
  final List<String> roles;
  final String? division;

  factory PreviewRecipient.fromJson(Map<String, dynamic> j) => PreviewRecipient(
        email: (j["email"] ?? "").toString(),
        roles: (j["roles"] is List ? j["roles"] as List : const <dynamic>[]).map((e) => e.toString()).toList(),
        division: j["division"]?.toString(),
      );
}

/// Role keys sent by the server -> FR / EN words.
String roleLabel(String role, {required bool french}) {
  const fr = <String, String>{
    "creator": "Division créatrice", "receiver": "Division réceptrice", "origin": "Division de départ",
    "carrier": "Transporteur", "dispatcher": "Répartiteur / logistique", "fallback": "Comptabilité (par défaut)",
  };
  const en = <String, String>{
    "creator": "Creating division", "receiver": "Receiving division", "origin": "Leaving division",
    "carrier": "Carrier", "dispatcher": "Dispatcher / logistics", "fallback": "Accounting (default)",
  };
  return (french ? fr : en)[role] ?? role;
}

class PreviewResult {
  const PreviewResult({required this.recipients, required this.deliveredTo, required this.testMode, required this.unresolved});
  final List<PreviewRecipient> recipients;
  final List<String> deliveredTo;
  final bool testMode;
  final List<String> unresolved;

  factory PreviewResult.fromJson(Map<String, dynamic> j) => PreviewResult(
        recipients: (j["recipients"] is List ? j["recipients"] as List : const <dynamic>[])
            .whereType<Map>()
            .map((e) => PreviewRecipient.fromJson(e.cast<String, dynamic>()))
            .toList(),
        deliveredTo: (j["deliveredTo"] is List ? j["deliveredTo"] as List : const <dynamic>[]).map((e) => e.toString()).toList(),
        testMode: j["testMode"] == true,
        unresolved: (j["unresolved"] is List ? j["unresolved"] as List : const <dynamic>[]).map((e) => e.toString()).toList(),
      );
}

class SubmitResult {
  const SubmitResult({required this.changeId, required this.emailStatus, required this.duplicate, required this.testMode});
  final String changeId;
  final String emailStatus;
  final bool duplicate;
  final bool testMode;

  /// The change is saved even when the notice could not be sent.
  bool get emailFailed => emailStatus == "failed" || emailStatus == "throttled";

  factory SubmitResult.fromJson(Map<String, dynamic> j) => SubmitResult(
        changeId: (j["changeId"] ?? "").toString(),
        emailStatus: (j["emailStatus"] ?? "").toString(),
        duplicate: j["duplicate"] == true,
        testMode: j["testMode"] == true,
      );
}

/// One saved change (one or more fields) in the history list.
class ChangeGroup {
  const ChangeGroup({required this.changeId, required this.changedBy, required this.changedAt, required this.reason, required this.fields});
  final String changeId;
  final String changedBy;
  final String changedAt;
  final String reason;
  final List<FieldChange> fields;

  factory ChangeGroup.fromJson(Map<String, dynamic> j) => ChangeGroup(
        changeId: (j["changeId"] ?? "").toString(),
        changedBy: (j["changedBy"] ?? "").toString(),
        changedAt: (j["changedAt"] ?? "").toString(),
        reason: (j["reason"] ?? "").toString(),
        fields: (j["fields"] is List ? j["fields"] as List : const <dynamic>[])
            .whereType<Map>()
            .map((e) => FieldChange.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );
}

class ChangedInfo {
  const ChangedInfo({required this.count, required this.lastBy, required this.lastAt});
  final int count;
  final String lastBy;
  final String lastAt;
}

/// "2026-11-05T14:03:00.000Z" -> "2026-11-05 14:03" (kept simple and timezone-free on purpose).
String shortStamp(String iso) {
  final m = RegExp(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})").firstMatch(iso);
  return m == null ? iso : "${m.group(1)} ${m.group(2)}";
}
