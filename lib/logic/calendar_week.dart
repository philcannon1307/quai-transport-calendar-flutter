import "../models/order.dart";
import "calendar_views.dart";
import "order_windows.dart";

/// Status of a calendar card, decoded from the NetSuite event status.
enum QuaiStatus { confirmed, tentative, cancelled }

/// null when the order carries no recognisable event status (no chip is shown).
QuaiStatus? statusOf(Order o) {
  final raw = "${o.eventStatus ?? ""}".toLowerCase();
  if (raw.contains("cancel") || raw.contains("annul")) return QuaiStatus.cancelled;
  if (raw.contains("tent") || raw.contains("prov")) return QuaiStatus.tentative;
  if (raw.contains("confirm")) return QuaiStatus.confirmed;
  return null;
}

/// Service rail / tag family (colour comes from the tokens).
enum ServiceKind { install, delivery, pickup, transfer }

ServiceKind serviceKindOf(Order o) {
  if (o.isTransfer) return ServiceKind.transfer;
  final s = (o.serviceType ?? "").toLowerCase();
  if (calendarView(o) == CalendarViewKind.pickups) return ServiceKind.pickup;
  if (s.contains("install")) return ServiceKind.install;
  return ServiceKind.delivery;
}

/// "Location" is the French word for rental: counted in the KPI tile.
bool isRental(Order o) {
  final s = (o.serviceType ?? "").toLowerCase();
  return s.contains("location") || s.contains("rental");
}

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// Monday of the week containing [d].
DateTime mondayOf(DateTime d) {
  final day = dateOnly(d);
  return DateTime(day.year, day.month, day.day - (day.weekday - DateTime.monday));
}

/// `count` consecutive days from [start] (DST safe: calendar arithmetic, not Durations).
List<DateTime> daysFrom(DateTime start, int count) =>
    List<DateTime>.generate(count, (i) => DateTime(start.year, start.month, start.day + i));

/// Orders grouped by calendar day (midnight keys). Orders without a parseable date are dropped.
Map<DateTime, List<Order>> ordersByDay(Iterable<Order> orders) {
  final out = <DateTime, List<Order>>{};
  for (final o in orders) {
    final d = OrderWindows.parseDate(o.date);
    if (d == null) continue;
    out.putIfAbsent(dateOnly(d), () => <Order>[]).add(o);
  }
  return out;
}

/// Cancelled cards sort last inside a day; otherwise the incoming order is kept.
List<Order> sortedForDay(List<Order> orders) {
  final list = List<Order>.of(orders);
  int rank(Order o) => statusOf(o) == QuaiStatus.cancelled ? 1 : 0;
  final indexed = <MapEntry<int, Order>>[for (var i = 0; i < list.length; i++) MapEntry(i, list[i])];
  indexed.sort((a, b) {
    final r = rank(a.value).compareTo(rank(b.value));
    return r != 0 ? r : a.key.compareTo(b.key);
  });
  return indexed.map((e) => e.value).toList();
}

/// The day highlighted for a week: the picked day if it lies in the week, else today, else Monday.
DateTime effectiveSelectedDay({required DateTime? picked, required DateTime weekStart, required DateTime today}) {
  final days = daysFrom(weekStart, 7);
  if (picked != null && days.any((d) => sameDay(d, picked))) return dateOnly(picked);
  if (days.any((d) => sameDay(d, today))) return dateOnly(today);
  return weekStart;
}
