import "package:flutter/material.dart";

import "../i18n/i18n.dart";
import "../logic/calendar_week.dart";
import "../models/order.dart";
import "../screens/ticket_sheet.dart";
import "../theme/quai_tokens.dart";
import "../widgets/adjustment_sheet.dart";
import "../widgets/bilingual.dart";
import "../widgets/contact_links.dart";
import "../widgets/status_chip.dart";

/// Rail / dot colour of a service family.
Color serviceColor(QuaiColors c, ServiceKind k) => switch (k) {
      ServiceKind.install => c.install,
      ServiceKind.delivery => c.delivery,
      ServiceKind.pickup => c.pickup,
      ServiceKind.transfer => c.transfer,
    };

/// Text colour of a service tag (delivery uses the darker teal for contrast).
Color serviceTextColor(QuaiColors c, ServiceKind k) => k == ServiceKind.delivery ? c.deliveryText : serviceColor(c, k);

/// Order card: 5 px service rail on the left, SO# in mono, status chip top-right, client name,
/// destination, service tag and round call / navigate actions. The whole card opens the order sheet.
/// `dense` is the narrower week-grid variant (cards ~163 px wide).
class OrderCard extends StatelessWidget {
  const OrderCard({super.key, required this.order, required this.now, this.dense = false});
  final Order order;
  final DateTime now;
  final bool dense;

  String? get _destination {
    if (order.isTransfer) return null;
    for (final v in <String?>[order.city, order.saleLocationName, order.shippingLocationName]) {
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    final s = StringsScope.of(context);
    final status = statusOf(order);
    final cancelled = status == QuaiStatus.cancelled;
    final kind = serviceKindOf(order);
    final rail = cancelled ? c.faint : serviceColor(c, kind);
    final tagColor = cancelled ? c.sub : serviceTextColor(c, kind);
    final dest = _destination;
    final date = OrderDate.of(order);
    final past = date != null && date.isBefore(OrderDate.businessDay(now)) && !cancelled;

    final nameStyle = quaiSans(cancelled ? c.sub : c.ink, size: dense ? 13 : 15, height: dense ? 16 : 20, weight: FontWeight.w700)
        .copyWith(decoration: cancelled ? TextDecoration.lineThrough : null);

    final header = Row(children: <Widget>[
      Flexible(child: Text(order.soNum, overflow: TextOverflow.ellipsis, style: quaiMono(cancelled ? c.faint : c.sub, size: dense ? 10.5 : 12))),
      if (order.isTransfer) ...<Widget>[
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(QuaiRadius.xs), border: Border.all(color: c.line)),
          child: Text("TO", style: quaiSans(c.sub, size: 10, height: 12, weight: FontWeight.w700)),
        ),
      ],
      if (!dense) ...<Widget>[const Spacer(), if (status != null) StatusChip(status: status)],
    ]);

    final tag = Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
      Container(width: 8, height: 8, decoration: BoxDecoration(color: cancelled ? c.faint : serviceColor(c, kind), shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          (order.serviceType ?? "").isEmpty ? s.svc(kind.name == "install" ? "installation" : kind.name) : order.serviceType!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: quaiSans(tagColor, size: dense ? 10.5 : 12.5, height: 16, weight: FontWeight.w700),
        ),
      ),
    ]);

    final actions = Wrap(spacing: dense ? 4 : 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
      if (!order.isTransfer) ContactLinks(soNum: order.soNum, round: true, small: dense),
      _RoundAction(
        buttonKey: Key("report-${order.soNum}"),
        tooltip: bi(s, "Signaler", "Report"),
        icon: Icons.flag_outlined,
        small: dense,
        onTap: () => showAdjustmentSheet(context, order),
      ),
    ]);

    final body = Padding(
      padding: EdgeInsets.fromLTRB(dense ? 10 : 14, dense ? 8 : 12, dense ? 8 : 12, dense ? 8 : 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: <Widget>[
        if (dense && status != null) ...<Widget>[StatusChip(status: status), const SizedBox(height: 4)],
        header,
        SizedBox(height: dense ? 2 : 4),
        if ((order.customer ?? "").isNotEmpty) Text(order.customer!, maxLines: 2, overflow: TextOverflow.ellipsis, style: nameStyle),
        if (dest != null) ...<Widget>[
          SizedBox(height: dense ? 2 : 3),
          Row(children: <Widget>[
            Icon(Icons.place_outlined, size: dense ? 12 : 14, color: c.faint),
            const SizedBox(width: 3),
            Expanded(child: Text(dest, maxLines: 1, overflow: TextOverflow.ellipsis, style: quaiSans(c.sub, size: dense ? 10.5 : 13, height: 16))),
          ]),
        ],
        SizedBox(height: dense ? 6 : 8),
        if (dense) ...<Widget>[tag, const SizedBox(height: 4), actions] else Row(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[Expanded(child: tag), actions]),
      ]),
    );

    return Opacity(
      opacity: past ? 0.72 : 1,
      child: Container(
        margin: EdgeInsets.only(bottom: dense ? 8 : 10),
        decoration: BoxDecoration(borderRadius: QuaiRadius.cardR, boxShadow: quaiShadow(c)),
        child: Material(
          color: c.surface,
          clipBehavior: Clip.antiAlias,
          shape: const RoundedRectangleBorder(borderRadius: QuaiRadius.cardR),
          child: InkWell(
            key: Key("card-${order.soNum}"),
            onTap: () => showTicketSheet(context, order.soNum),
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                Container(key: Key("rail-${order.soNum}"), width: 5, color: rail),
                Expanded(child: body),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Date helpers shared by the card (same 2 AM business-day rule as the rest of the app).
class OrderDate {
  static DateTime? of(Order o) {
    final d = DateTime.tryParse(o.date.trim());
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }

  static DateTime businessDay(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return now.hour < 2 ? DateTime(today.year, today.month, today.day - 1) : today;
  }
}

/// 36 px circular outlined action (44 px tap target through padding).
class _RoundAction extends StatelessWidget {
  const _RoundAction({required this.buttonKey, required this.tooltip, required this.icon, required this.onTap, this.small = false});
  final Key buttonKey;
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool small;

  @override
  Widget build(BuildContext context) => RoundIconButton(key: buttonKey, tooltip: tooltip, icon: icon, onTap: onTap, small: small);
}
