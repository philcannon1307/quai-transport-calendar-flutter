import "package:flutter/material.dart";

import "../i18n/i18n.dart";
import "../logic/calendar_views.dart";
import "../models/order.dart";

/// SADM - Logistique's three calendars: Deliveries & Installations, Pick-ups, TOs.
class LogistiqueTabs extends StatelessWidget {
  const LogistiqueTabs({super.key, required this.selected, required this.orders, required this.onChanged});

  final CalendarViewKind selected;
  final List<Order> orders;
  final ValueChanged<CalendarViewKind> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = StringsScope.of(context);
    int count(CalendarViewKind k) => orders.where((o) => calendarView(o) == k).length;
    String label(String key, CalendarViewKind k) => "${s.t(key)} (${count(k)})";
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<CalendarViewKind>(
          showSelectedIcon: false,
          segments: <ButtonSegment<CalendarViewKind>>[
            ButtonSegment<CalendarViewKind>(
              value: CalendarViewKind.delivInst,
              label: Text(label("views.delivInst", CalendarViewKind.delivInst), overflow: TextOverflow.ellipsis),
            ),
            ButtonSegment<CalendarViewKind>(
              value: CalendarViewKind.pickups,
              label: Text(label("views.pickups", CalendarViewKind.pickups), overflow: TextOverflow.ellipsis),
            ),
            ButtonSegment<CalendarViewKind>(
              value: CalendarViewKind.transfers,
              label: Text(label("views.transfers", CalendarViewKind.transfers), overflow: TextOverflow.ellipsis),
            ),
          ],
          selected: <CalendarViewKind>{selected},
          onSelectionChanged: (v) => onChanged(v.first),
        ),
      ),
    );
  }
}
