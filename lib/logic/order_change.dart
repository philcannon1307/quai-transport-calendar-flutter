import "../models/order.dart";

/// One editable field of an order / picking ticket (keys match the server's allow-list).
class ChangeField {
  const ChangeField(this.key, this.fr, this.en,
      {this.transferOnly = false, this.orderOnly = false});
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
  ChangeField("receiving_location", "Lieu de réception", "Receiving location",
      transferOnly: true),
  ChangeField("service_type", "Type de service", "Service type",
      orderOnly: true),
  ChangeField("status_note", "Statut", "Status"),
  ChangeField("memo", "Mémo", "Memo"),
];

/// The fields shown for [order] (transfer-only / order-only ones are filtered).
List<ChangeField> fieldsFor(Order order) => kChangeFields
    .where((f) => order.isTransfer ? !f.orderOnly : !f.transferOnly)
    .toList();

/// Calendar names can end with a stray "/" (e.g. "SADM - Jayson/"): not a value worth saving.
String _tidy(String? v) => (v ?? "").replaceAll(RegExp(r"[\s/]+$"), "");

/// Latest saved value per field from the history (any order of groups). Only the given keys are returned.
Map<String, String> latestSavedValues(
    List<ChangeGroup> groups, Iterable<String> keys) {
  final wanted = keys.toSet();
  final out = <String, String>{};
  final at = <String, String>{};
  for (final g in groups) {
    for (final f in g.fields) {
      if (!wanted.contains(f.field)) continue;
      final prev = at[f.field];
      if (prev == null || g.changedAt.compareTo(prev) >= 0) {
        at[f.field] = g.changedAt;
        out[f.field] = f.newValue;
      }
    }
  }
  return out;
}

/// What the ticket shows today, per field key. Unknown values are empty strings.
Map<String, String> currentValues(Order o) => <String, String>{
      "ship_date": o.shipDate ?? o.date,
      "truck": _tidy(o.truckName),
      "carrier": _tidy(o.carrierName),
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
      if ((o.shippingLocationName ?? "").isNotEmpty)
        "shippingLocationName": o.shippingLocationName!,
      if (o.isTransfer && (o.saleLocationName ?? "").isNotEmpty)
        "saleLocationName": o.saleLocationName!,
      if ((o.carrierName ?? o.truckName ?? "").isNotEmpty)
        "carrierName": (o.carrierName ?? o.truckName)!,
      if (!o.isTransfer && (o.customer ?? "").isNotEmpty)
        "customer": o.customer!,
    };

class FieldChange {
  const FieldChange(
      {required this.field,
      required this.oldValue,
      required this.newValue,
      this.note = ""});
  final String field;
  final String oldValue;
  final String newValue;

  /// Per-line note (line-by-line changes only; legacy field entries have none).
  final String note;

  /// A modified article line ("item:NAME") as opposed to a legacy field entry or a note-only entry.
  bool get isItem => field.startsWith("item:");
  bool get isNote => field == "note";
  String get itemName => isItem ? field.substring(5) : "";

  /// One readable line for history: "2x4 : 10 → 8 (Quantité modifiée) — note"; legacy fields keep "Label : old → new".
  String summary({required bool french}) {
    if (isNote) return newValue;
    final o = oldValue.isEmpty ? "—" : oldValue;
    final n = newValue.isEmpty ? "—" : newValue;
    if (!isItem) return label(french: french) + " : " + o + " → " + n;
    final a = lineActionLabel(lineActionOf(oldValue, newValue), french: french);
    return itemName +
        " : " +
        (oldValue.isEmpty ? "0" : oldValue) +
        " → " +
        (newValue.isEmpty ? "0" : newValue) +
        " (" +
        a +
        ")" +
        (note.isEmpty ? "" : " — " + note);
  }

  Map<String, String> toJson() =>
      <String, String>{"field": field, "old": oldValue, "new": newValue};

  factory FieldChange.fromJson(Map<String, dynamic> j) => FieldChange(
        field: (j["field"] ?? "").toString(),
        oldValue: (j["old"] ?? "").toString(),
        newValue: (j["new"] ?? "").toString(),
        note: (j["note"] ?? "").toString(),
      );

  /// Human label, FR or EN. "item:2x4" -> "Article : 2x4".
  String label({required bool french}) {
    for (final f in kChangeFields) {
      if (f.key == field) return french ? f.fr : f.en;
    }
    if (field == "note") return french ? "Mémo" : "Note";
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
List<FieldChange> diffChanges(
    Map<String, String> before, Map<String, String> after,
    {List<ItemEdit> items = const <ItemEdit>[]}) {
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
    if (name.isEmpty || from == to || name.length > 70 || !seen.add(name))
      continue;
    out.add(FieldChange(field: "item:$name", oldValue: from, newValue: to));
  }
  return out;
}

/// What happened to an article line, derived from the quantities: "added" (0 -> n), "removed" (n -> 0), else "changed".
String lineActionOf(String before, String after) {
  final b = int.tryParse(before.trim().isEmpty ? "0" : before.trim());
  final a = int.tryParse(after.trim());
  if (b != null && a != null) {
    if (b == 0 && a > 0) return "added";
    if (a == 0 && b > 0) return "removed";
  }
  return "changed";
}

String lineActionLabel(String action, {required bool french}) {
  switch (action) {
    case "added":
      return french ? "Ajouté" : "Added";
    case "removed":
      return french ? "Retiré" : "Removed";
    default:
      return french ? "Quantité modifiée" : "Quantity changed";
  }
}

/// Server limits, mirrored here so the form refuses early.
const int kMaxChangeLines = 50;
const int kMaxItemName = 70;

/// One modified article line typed by the user: [before] blank means 0 (a line added to the order).
class ChangeLine {
  const ChangeLine(
      {this.item = "", this.before = "", this.after = "", this.note = ""});
  final String item;
  final String before;
  final String after;
  final String note;

  String get action => lineActionOf(before, after);

  Map<String, String> toJson() => <String, String>{
        "item": item.trim(),
        "before": before.trim(),
        "after": after.trim(),
        if (note.trim().isNotEmpty) "note": note.trim(),
      };
}

final RegExp _qty = RegExp(r"^\d{1,6}$");

/// Why [l] cannot be sent, or null when it is fine: "item" (missing/too long name), "before" / "after" (not an integer >= 0),
/// "same" (quantity unchanged).
String? lineIssue(ChangeLine l) {
  final name = l.item.trim();
  if (name.isEmpty || name.length > kMaxItemName) return "item";
  final b = l.before.trim();
  if (b.isNotEmpty && !_qty.hasMatch(b)) return "before";
  if (!_qty.hasMatch(l.after.trim())) return "after";
  if ((b.isEmpty ? 0 : int.parse(b)) == int.parse(l.after.trim()))
    return "same";
  return null;
}

/// First problem across the lines ({index, key}) or null. Duplicated article names are also refused (the server does too).
({int index, String key})? firstLineIssue(List<ChangeLine> lines) {
  final seen = <String>{};
  for (var i = 0; i < lines.length; i++) {
    final k = lineIssue(lines[i]);
    if (k != null) return (index: i, key: k);
    if (!seen.add(lines[i].item.trim().toLowerCase()))
      return (index: i, key: "duplicate");
  }
  return null;
}

class PreviewRecipient {
  const PreviewRecipient(
      {required this.email, required this.roles, this.division});
  final String email;
  final List<String> roles;
  final String? division;

  factory PreviewRecipient.fromJson(Map<String, dynamic> j) => PreviewRecipient(
        email: (j["email"] ?? "").toString(),
        roles: (j["roles"] is List ? j["roles"] as List : const <dynamic>[])
            .map((e) => e.toString())
            .toList(),
        division: j["division"]?.toString(),
      );
}

/// Role keys sent by the server -> FR / EN words.
String roleLabel(String role, {required bool french}) {
  const fr = <String, String>{
    "creator": "Division créatrice",
    "receiver": "Division réceptrice",
    "origin": "Division de départ",
    "carrier": "Transporteur",
    "dispatcher": "Répartiteur / logistique",
    "fallback": "Comptabilité (par défaut)",
  };
  const en = <String, String>{
    "creator": "Creating division",
    "receiver": "Receiving division",
    "origin": "Leaving division",
    "carrier": "Carrier",
    "dispatcher": "Dispatcher / logistics",
    "fallback": "Accounting (default)",
  };
  return (french ? fr : en)[role] ?? role;
}

class PreviewResult {
  const PreviewResult(
      {required this.recipients,
      required this.deliveredTo,
      required this.testMode,
      required this.unresolved});
  final List<PreviewRecipient> recipients;
  final List<String> deliveredTo;
  final bool testMode;
  final List<String> unresolved;

  factory PreviewResult.fromJson(Map<String, dynamic> j) => PreviewResult(
        recipients: (j["recipients"] is List
                ? j["recipients"] as List
                : const <dynamic>[])
            .whereType<Map>()
            .map((e) => PreviewRecipient.fromJson(e.cast<String, dynamic>()))
            .toList(),
        deliveredTo: (j["deliveredTo"] is List
                ? j["deliveredTo"] as List
                : const <dynamic>[])
            .map((e) => e.toString())
            .toList(),
        testMode: j["testMode"] == true,
        unresolved: (j["unresolved"] is List
                ? j["unresolved"] as List
                : const <dynamic>[])
            .map((e) => e.toString())
            .toList(),
      );
}

class SubmitResult {
  const SubmitResult(
      {required this.changeId,
      required this.emailStatus,
      required this.duplicate,
      required this.testMode});
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
  const ChangeGroup(
      {required this.changeId,
      required this.changedBy,
      required this.changedAt,
      required this.reason,
      required this.fields});
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
  const ChangedInfo(
      {required this.count, required this.lastBy, required this.lastAt});
  final int count;
  final String lastBy;
  final String lastAt;
}

/// "2026-11-05T14:03:00.000Z" -> "2026-11-05 14:03" (kept simple and timezone-free on purpose).
String shortStamp(String iso) {
  final m = RegExp(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})").firstMatch(iso);
  return m == null ? iso : "${m.group(1)} ${m.group(2)}";
}
