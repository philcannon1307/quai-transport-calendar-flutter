import "package:flutter/material.dart";
import "package:intl/intl.dart";

import "../i18n/i18n.dart";
import "../logic/calendar_week.dart";
import "../models/order.dart";
import "../theme/quai_tokens.dart";
import "bilingual.dart";
import "order_card.dart";

/// Locale-aware date / count strings for the calendar.
class CalFmt {
  CalFmt(this.s) : loc = s.isFrench ? "fr_CA" : "en_CA";
  final Strings s;
  final String loc;

  static String cap(String v) =>
      v.isEmpty ? v : v[0].toUpperCase() + v.substring(1);

  /// "2 – 8 novembre 2026" or "30 sept. – 6 oct. 2026".
  String range(DateTime a, DateTime b) {
    if (a.month == b.month && a.year == b.year) {
      return "${a.day} – ${b.day} ${DateFormat.MMMM(loc).format(b)} ${b.year}";
    }
    return "${a.day} ${DateFormat.MMM(loc).format(a)} – ${b.day} ${DateFormat.MMM(loc).format(b)} ${b.year}";
  }

  /// "Mercredi 4 novembre".
  String dayLong(DateTime d) => cap(DateFormat("EEEE d MMMM", loc).format(d));

  /// "Lun. 2 nov." / "Mer. 4 nov."
  String dayShort(DateTime d) => cap(DateFormat("E d MMM", loc).format(d));

  /// "LUN" from the ported dictionary (dow.0 = Monday).
  String dow(DateTime d) => s.dow(d.weekday - 1).toUpperCase();

  String count(int n) => "$n ${s.t(n == 1 ? "cal.order" : "cal.orders")}";

  String countWithCancelled(List<Order> orders) {
    final cancelled =
        orders.where((o) => statusOf(o) == QuaiStatus.cancelled).length;
    if (cancelled == 0) return count(orders.length);
    return "${count(orders.length)} · $cancelled ${bi(s, cancelled == 1 ? "annulée" : "annulées", "cancelled")}";
  }
}

/// KPI tile. Active = orange tint + 1.4 px orange border. `wide` is the 96 px web card.
class KpiTile extends StatelessWidget {
  const KpiTile(
      {super.key,
      required this.label,
      required this.value,
      this.active = false,
      this.wide = false,
      this.caption,
      this.progress});
  final String label;
  final String value;
  final bool active;
  final bool wide;
  final String? caption;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    final fg = active ? c.primaryInk : c.ink;
    return Container(
      height: wide ? 96 : 62,
      padding: EdgeInsets.fromLTRB(
          wide ? 18 : 12, wide ? 14 : 8, wide ? 18 : 12, wide ? 12 : 6),
      decoration: BoxDecoration(
        color: active ? c.primarySoft : c.surface,
        borderRadius:
            BorderRadius.circular(wide ? QuaiRadius.lg - 2 : QuaiRadius.card),
        border: Border.all(
            color:
                active ? c.primary : c.line.withValues(alpha: wide ? 1 : 0.0),
            width: active ? 1.4 : 1),
        boxShadow: wide ? null : quaiShadow(c),
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: quaiSans(active ? c.primaryInk : c.sub,
                    size: wide ? 11 : 9.5,
                    height: 12,
                    weight: FontWeight.w700,
                    ls: .8)),
            SizedBox(height: wide ? 6 : 2),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
              Flexible(
                  flex: 3,
                  child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(value,
                          maxLines: 1,
                          style: quaiSans(fg,
                              size: wide ? 36 : 25,
                              height: wide ? 40 : 30,
                              weight: FontWeight.w700)))),
              if (wide && caption != null) ...<Widget>[
                const SizedBox(width: 10),
                Flexible(
                    flex: 2,
                    child: Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(caption!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: quaiSans(c.sub, size: 11.5, height: 14)))),
              ],
            ]),
            if (wide && progress != null) ...<Widget>[
              const Spacer(),
              ClipRRect(
                borderRadius: BorderRadius.circular(QuaiRadius.full),
                child: LinearProgressIndicator(
                    value: progress!.clamp(0, 1).toDouble(),
                    minHeight: 4,
                    backgroundColor: c.primary.withValues(alpha: .18),
                    color: c.primary),
              ),
            ],
          ]),
    );
  }
}

/// Little legend: coloured dot + service name.
class ServiceLegend extends StatelessWidget {
  const ServiceLegend({super.key, required this.kinds});
  final List<ServiceKind> kinds;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    final s = StringsScope.of(context);
    String name(ServiceKind k) => switch (k) {
          ServiceKind.install => s.t("svc.installation"),
          ServiceKind.delivery => s.t("svc.delivery"),
          ServiceKind.pickup => s.t("svc.pickup"),
          ServiceKind.transfer => bi(s, "Transfert", "Transfer"),
        };
    return Wrap(spacing: 14, runSpacing: 4, children: <Widget>[
      for (final k in kinds)
        Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: serviceColor(c, k), shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(name(k), style: quaiSans(c.sub, size: 12, height: 16)),
        ]),
    ]);
  }
}

/// Circular outlined icon button (previous / next period).
class CircleNavButton extends StatelessWidget {
  const CircleNavButton(
      {super.key,
      required this.icon,
      required this.onTap,
      required this.tooltip,
      this.buttonKey});
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        key: buttonKey,
        onTap: onTap,
        radius: 26,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.surface,
              border: Border.all(color: c.line)),
          child: Icon(icon, size: 20, color: c.ink),
        ),
      ),
    );
  }
}

/// "Auj." / "Cette semaine" pill: orange-ink text on white (orange text only >= 14 px bold).
class PillButton extends StatelessWidget {
  const PillButton(
      {super.key, required this.label, required this.onTap, this.buttonKey});
  final String label;
  final VoidCallback onTap;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    return InkWell(
      key: buttonKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(QuaiRadius.full),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(QuaiRadius.full),
            border: Border.all(color: c.line)),
        child: Text(label,
            style: quaiSans(c.primaryInk, size: 14, weight: FontWeight.w700)),
      ),
    );
  }
}

/// Banner (warnings): warm memo callout = orange rail on warm tint.
class MemoBanner extends StatelessWidget {
  const MemoBanner({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
          color: c.memoBg, borderRadius: BorderRadius.circular(QuaiRadius.sm)),
      child: IntrinsicHeight(
        child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                  width: 4,
                  decoration: BoxDecoration(
                      color: c.memoRail,
                      borderRadius: const BorderRadius.horizontal(
                          left: Radius.circular(QuaiRadius.sm)))),
              Expanded(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(text,
                          style: quaiSans(c.ink, size: 12.5, height: 17)))),
            ]),
      ),
    );
  }
}

class CalMessage extends StatelessWidget {
  const CalMessage({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(text,
                textAlign: TextAlign.center,
                style: quaiSans(context.q.sub, size: 13))),
      );
}
