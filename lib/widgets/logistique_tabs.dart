import "package:flutter/material.dart";

import "../i18n/i18n.dart";
import "../logic/calendar_views.dart";
import "../models/order.dart";
import "../theme/quai_tokens.dart";
import "bilingual.dart";

/// SADM - Logistique's three calendars as a segmented pill: Deliveries & Installations, Pick-ups, TOs.
/// Active segment = brand orange with ink label and the count in a lighter tone. `tall` is the web variant (52 px).
class LogistiqueTabs extends StatelessWidget {
  const LogistiqueTabs({super.key, required this.selected, required this.orders, required this.onChanged, this.tall = false});

  final CalendarViewKind selected;
  final List<Order> orders;
  final ValueChanged<CalendarViewKind> onChanged;
  final bool tall;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    final s = StringsScope.of(context);
    int count(CalendarViewKind k) => orders.where((o) => calendarView(o) == k).length;
    // Phone labels are shortened so the three segments fit in 358 px.
    String label(CalendarViewKind k) {
      switch (k) {
        case CalendarViewKind.delivInst:
          return tall ? s.t("views.delivInst") : bi(s, "Livr. & Install.", "Deliv. & Install.");
        case CalendarViewKind.pickups:
          return s.t("views.pickups");
        case CalendarViewKind.transfers:
          return tall ? s.t("views.transfers") : bi(s, "Transferts", "Transfers");
      }
    }

    Widget seg(CalendarViewKind k) {
      final active = k == selected;
      return Expanded(
        flex: k == CalendarViewKind.delivInst ? 5 : 4,
        child: GestureDetector(
          key: Key("tab-${k.name}"),
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(k),
          child: AnimatedContainer(
            duration: QuaiMotion.segment,
            curve: QuaiMotion.out,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: active ? c.primary : Colors.transparent, borderRadius: BorderRadius.circular(QuaiRadius.full)),
            child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
              Flexible(
                child: Text(label(k), maxLines: 1, overflow: TextOverflow.ellipsis, style: quaiSans(active ? c.onPrimary : c.sub, size: tall ? 14 : 13, weight: FontWeight.w700)),
              ),
              const SizedBox(width: 6),
              Text("${count(k)}", style: quaiSans(active ? c.onPrimary.withValues(alpha: .7) : c.faint, size: tall ? 13 : 12, weight: FontWeight.w600)),
            ]),
          ),
        ),
      );
    }

    return Container(
      height: tall ? 52 : 42,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(QuaiRadius.full)),
      child: Row(children: <Widget>[seg(CalendarViewKind.delivInst), seg(CalendarViewKind.pickups), seg(CalendarViewKind.transfers)]),
    );
  }
}
