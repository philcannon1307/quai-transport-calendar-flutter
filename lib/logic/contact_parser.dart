import "dart:convert";

class OrderContact {
  const OrderContact({this.phone, this.address});
  final String? phone;
  final String? address;

  bool get isEmpty => phone == null && address == null;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{"phone": phone, "address": address};

  factory OrderContact.fromJson(Map<String, dynamic> j) => OrderContact(
      phone: j["phone"] as String?, address: j["address"] as String?);

  String encode() => jsonEncode(toJson());
}

/// Splits extracted PDF text into lines.
List<String> linesFromPdfText(String text) => text.split(RegExp(r"\r?\n"));

/// Ship-to phone + address from the picking-ticket text (template 146).
/// Ported from orderContact.ts: the address is the block between the "Client"
/// heading and the phone line, minus the customer name (its first line).
OrderContact parseContact(List<String> lines, String soNum) {
  final clean = lines.map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  final phoneRe = RegExp(r"^(phone|t[ée]l[ée]phone)\s*:", caseSensitive: false);
  final clientRe = RegExp(r"^client\s*:?", caseSensitive: false);

  final phoneIdx = clean.indexWhere(phoneRe.hasMatch);
  String? phone;
  if (phoneIdx >= 0) {
    final value = clean[phoneIdx].split(":").sublist(1).join(":").trim();
    phone = value.isEmpty ? null : value;
  }

  String? address;
  final clientIdx = clean.indexWhere(clientRe.hasMatch);
  if (clientIdx >= 0 && phoneIdx > clientIdx) {
    final block = clean
        .sublist(clientIdx + 1, phoneIdx)
        .where((l) =>
            l.toUpperCase() != soNum.toUpperCase() && !clientRe.hasMatch(l))
        .toList();
    final addr = block.skip(1).toList();
    if (addr.isNotEmpty) address = addr.join(", ");
  }
  return OrderContact(phone: phone, address: address);
}

String telHref(String phone) =>
    "tel:${phone.replaceAll(RegExp(r"[^\d+]"), "")}";

String mapsHref(String address) =>
    "https://www.google.com/maps/dir/?api=1&destination=${Uri.encodeComponent(address)}";
