/// One line of a change report: planned quantity -> actual quantity.
class AdjustmentRow {
  const AdjustmentRow({this.item = "", this.from = "", this.to = "", this.reason = ""});
  final String item;
  final String from;
  final String to;
  final String reason;

  AdjustmentRow copyWith({String? item, String? from, String? to, String? reason}) => AdjustmentRow(
        item: item ?? this.item,
        from: from ?? this.from,
        to: to ?? this.to,
        reason: reason ?? this.reason,
      );

  AdjustmentRow trimmed() => AdjustmentRow(item: item.trim(), from: from.trim(), to: to.trim(), reason: reason.trim());

  Map<String, String> toJson() => <String, String>{"item": item, "from": from, "to": to, "reason": reason};
}

/// Rows that actually name an item (blank rows are dropped), trimmed.
List<AdjustmentRow> filledRows(List<AdjustmentRow> rows) =>
    rows.where((r) => r.item.trim().isNotEmpty).map((r) => r.trimmed()).toList();

/// "TO" for transfer orders, "SO" for sales orders (reference: startsWith("TO")).
String adjustmentKind(String orderNum) => orderNum.toUpperCase().startsWith("TO") ? "TO" : "SO";

/// Change reports may only ever go to a Groupe QL mailbox. The recipients come
/// from our own routing table, but the email function accepts any address from
/// the caller, so this is a last line of defence against becoming a mail relay.
bool isGroupeQlAddress(String email) =>
    RegExp(r"^[^@\s]+@groupeql\.com$", caseSensitive: false).hasMatch(email.trim());
