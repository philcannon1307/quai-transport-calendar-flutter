/// Date-window rules for the calendar and "Mes commandes".
///
/// THE 2 AM RULE. The reference app turns past cards red "at 2 AM"
/// (anchor: Admin.tsx:60, setHours(2)). The correct model is a BUSINESS DAY
/// that rolls over at 02:00 local, not a single cutoff instant:
///
///   * before 02:00 the current business day is still YESTERDAY's date, so
///     yesterday's jobs remain "today's work" for a driver finishing late;
///   * from 02:00 onwards the business day becomes today, and anything dated
///     earlier flips to past (red).
///
/// My first implementation compared against one cutoff instant, which wrongly
/// marked TODAY's own cards as past at exactly 02:00 and kept yesterday green
/// at 01:59. The unit tests caught both.
///
/// STILL FOR REVIEW: the 02:00 boundary is inferred from the reference app's
/// behaviour, not read line-for-line. Confirm against the live React app
/// before parity sign-off.
class OrderWindows {
  /// Hour at which the working day rolls over.
  static const int rolloverHour = 2;

  /// Midnight-normalised date of the current business day.
  static DateTime businessDate(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return now.hour < rolloverHour ? today.subtract(const Duration(days: 1)) : today;
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// A card is "past" (rendered red) once its date precedes the business day.
  static bool isPast(DateTime orderDate, DateTime now) =>
      _dateOnly(orderDate).isBefore(businessDate(now));

  /// Upcoming window for "Mes commandes": 1 or 2 weeks ahead, current business
  /// day inclusive. Shares the rollover so the two views never disagree about
  /// what "today" means.
  static bool isUpcomingWithin(DateTime orderDate, DateTime now, int weeks) {
    final start = businessDate(now);
    final end = start.add(Duration(days: 7 * weeks));
    final d = _dateOnly(orderDate);
    return !d.isBefore(start) && d.isBefore(end);
  }

  /// Consecutive day columns for the calendar (7 or 14), from the business day.
  static List<DateTime> days(DateTime now, int count) {
    final start = businessDate(now);
    return List<DateTime>.generate(count, (i) => start.add(Duration(days: i)));
  }

  static DateTime? parseDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    return DateTime.tryParse(raw.trim());
  }
}
