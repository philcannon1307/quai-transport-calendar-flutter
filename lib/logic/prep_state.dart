import "../api/session.dart";
import "../models/order.dart";
import "calendar_views.dart";
import "calendar_week.dart";

/// Shared "Préparé" state of one order on one day (stored on the server, see server/src/data/prepState.js).
class PrepEntry {
  const PrepEntry({required this.prepared, this.by = "", this.label = "", this.at});

  final bool prepared;

  /// Login that made the change (e.g. "SADM - Logistique").
  final String by;

  /// Optional first name typed by the operator; wins over [by] when shown.
  final String label;
  final DateTime? at;

  String get who => label.isNotEmpty ? label : by;

  factory PrepEntry.fromJson(Map<String, dynamic> j) => PrepEntry(
        prepared: j["prepared"] == true,
        by: (j["by"] ?? "").toString(),
        label: (j["label"] ?? "").toString(),
        at: DateTime.tryParse((j["at"] ?? "").toString())?.toLocal(),
      );
}

/// Calendar day of a card, "YYYY-MM-DD": the second half of the server key.
String prepDateOf(Order o) {
  final d = o.date.trim();
  return d.length >= 10 ? d.substring(0, 10) : d;
}

/// Server key: order number + day. The same order on two days is prepared separately.
String prepKey(String orderNum, String date) => "${orderNum.trim().toUpperCase()}|$date";
String prepKeyOf(Order o) => prepKey(o.soNum, prepDateOf(o));

/// UI hint only (the server enforces it): logistics logins and the SuperUser may change the state.
bool canPrepare(String? role) => role == kRoleLogistique || role == kRoleSuperUser;

/// Cards that have a "prepared" state: everything except cancelled orders and customer pick-ups.
bool needsPrep(Order o) {
  if (statusOf(o) == QuaiStatus.cancelled) return false;
  if (o.isTransfer) return true;
  return calendarView(o) != CalendarViewKind.pickups;
}

String isoDay(DateTime d) =>
    "${d.year.toString().padLeft(4, "0")}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")}";

/// "Marc · 10:42" (today) or "Marc · 5/11 10:42" (another day).
String prepStamp(PrepEntry e, DateTime now) {
  String two(int n) => n.toString().padLeft(2, "0");
  final at = e.at;
  final who = e.who;
  if (at == null) return who;
  final t = "${two(at.hour)}:${two(at.minute)}";
  final sameDay = at.year == now.year && at.month == now.month && at.day == now.day;
  final when = sameDay ? t : "${at.day}/${at.month} $t";
  return who.isEmpty ? when : "$who · $when";
}

class PrepCount {
  const PrepCount(this.done, this.total);
  final int done;
  final int total;
  double get fraction => total == 0 ? 0 : done / total;
  bool get complete => total > 0 && done == total;
}

/// "X/Y préparées" for a day: cancelled orders and pick-ups are not counted.
PrepCount prepCount(Iterable<Order> orders, Map<String, PrepEntry> states) {
  var done = 0, total = 0;
  for (final o in orders) {
    if (!needsPrep(o)) continue;
    total++;
    if (states[prepKeyOf(o)]?.prepared == true) done++;
  }
  return PrepCount(done, total);
}

Map<String, PrepEntry> parsePrepStates(Map<String, dynamic> j) {
  final out = <String, PrepEntry>{};
  final list = j["states"];
  if (list is! List) return out;
  for (final e in list.whereType<Map>()) {
    final m = e.cast<String, dynamic>();
    final num = (m["orderNum"] ?? "").toString();
    if (num.isEmpty) continue;
    final entry = PrepEntry.fromJson(m);
    if (entry.prepared) out[prepKey(num, (m["date"] ?? "").toString())] = entry;
  }
  return out;
}
