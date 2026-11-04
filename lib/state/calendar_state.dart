import "package:flutter_riverpod/flutter_riverpod.dart";

/// Weeks away from the current business-day week (0 = this week, -1 = last week).
final weekOffsetProvider = StateProvider<int>((ref) => 0);

/// Day the user tapped in the strip / grid header; null = today (or Monday when today is outside the week).
final pickedDayProvider = StateProvider<DateTime?>((ref) => null);
