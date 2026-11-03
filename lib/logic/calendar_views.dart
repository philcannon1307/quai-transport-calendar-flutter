import "../models/order.dart";

/// Which of the three SADM - Logistique calendars an order belongs to.
enum CalendarViewKind { delivInst, pickups, transfers }

CalendarViewKind calendarView(Order o) {
  if (o.kind == OrderKind.transfer) return CalendarViewKind.transfers;
  final s = (o.serviceType ?? "").toLowerCase();
  if (s.contains("pick") || s.contains("cueill")) return CalendarViewKind.pickups;
  return CalendarViewKind.delivInst;
}

/// Classify a middleware calendar-event title (Ste-Agathe source).
CalendarViewKind calendarViewFromTitle(String title) {
  final s = title.toLowerCase();
  if (s.contains("ramassage") || s.contains("pick")) return CalendarViewKind.pickups;
  return CalendarViewKind.delivInst;
}
