import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../i18n/i18n.dart";
import "../logic/calendar_views.dart";
import "../logic/calendar_week.dart";
import "../state/calendar_state.dart";
import "../state/providers.dart";
import "../theme/quai_tokens.dart";
import "../widgets/bilingual.dart";
import "../widgets/brand_header.dart";
import "../widgets/calendar_common.dart";
import "../widgets/logistique_tabs.dart";
import "../widgets/order_card.dart";
import "../widgets/receipt_sheet.dart";
import "calendar_screen.dart";

/// Web / tablet layout: ink top bar, 4 KPI cards, full-width segmented tabs and a 7-column week grid
/// (>= 1100 px; 700-1099 px scrolls the grid horizontally by week-halves is replaced by a compact 7-col grid).
class WideCalendar extends ConsumerWidget {
  const WideCalendar(
      {super.key,
      required this.model,
      required this.status,
      required this.width});
  final CalendarModel? model;
  final Widget? status;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.q;
    final s = StringsScope.of(context);
    final m = model;
    final margin = width >= 1440 ? 80.0 : (width >= 1100 ? 40.0 : 20.0);
    return Scaffold(
      backgroundColor: c.bg,
      body: Column(children: <Widget>[
        _TopBar(
            carrierName:
                m?.carrierName ?? ref.watch(currentCarrierProvider) ?? ""),
        Expanded(
          child: m == null
              ? (status ?? const SizedBox.shrink())
              : SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(margin, 20, margin, 32),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                          maxWidth: QuaiSpace.pageMaxWidth),
                      child: _WideBody(m: m, s: s, width: width),
                    ),
                  ),
                ),
        ),
      ]),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.carrierName});
  final String carrierName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = StringsScope.of(context);
    final receipt = receiptButtonFor(carrierName,
        isSuperUser: ref.watch(sessionProvider).isSuperUser);
    Widget textBtn(String key, String label, VoidCallback onTap,
            {IconData? icon}) =>
        TextButton.icon(
          key: Key(key),
          onPressed: onTap,
          icon: icon == null
              ? const SizedBox.shrink()
              : Icon(icon, size: 16, color: Colors.white),
          label: Text(label,
              style: quaiSans(Colors.white, size: 13, weight: FontWeight.w600)),
        );
    return BrandHeader(
      height: 64 + MediaQuery.of(context).padding.top,
      padding:
          EdgeInsets.fromLTRB(24, MediaQuery.of(context).padding.top, 24, 0),
      child: Row(children: <Widget>[
        const BrandLogo(width: 150),
        Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            width: 1,
            height: 30,
            color: Colors.white24),
        Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(s.t("brand.tagline"),
                  style: quaiSans(context.q.headerSub, size: 10.5, height: 12)),
              Text(carrierName,
                  key: const Key("unit-name"),
                  style: quaiSans(Colors.white,
                      size: 15, height: 20, weight: FontWeight.w700)),
            ]),
        const SizedBox(width: 16),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
              const LangToggle(),
              const SizedBox(width: 16),
              if (receipt.show)
                OutlinedButton(
                  key: const Key("receipt-button"),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white38),
                      shape: const StadiumBorder()),
                  onPressed: () => showReceiptSheet(context, bol: receipt.bol),
                  child: Text(
                      s.t(receipt.bol ? "bol.button" : "receipts.button"),
                      style: quaiSans(Colors.white,
                          size: 13, weight: FontWeight.w700)),
                ),
              textBtn("nav-orders", s.t("dash.myOrders"),
                  () => Navigator.of(context).pushNamed("/my-orders")),
              textBtn("refresh-button", s.t("common.refresh"),
                  () => ref.invalidate(ordersLoadProvider),
                  icon: Icons.refresh),
              textBtn("logout-button", s.t("common.logout"),
                  () => signOutAndLeave(context, ref)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _WideBody extends ConsumerWidget {
  const _WideBody({required this.m, required this.s, required this.width});
  final CalendarModel m;
  final Strings s;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.q;
    final fmt = CalFmt(s);
    final days = daysFrom(m.weekStart, m.span == 14 ? 14 : 7);
    final weekOrders = m.ordersInRange(m.weekStart, days.length);
    final total = m.all.length;
    final filtered = m.shown.length;
    final rentals = m.ordersInRange(m.weekStart, 7).where(isRental).length;
    final compact = width < QuaiBreakpoints.wide;

    Widget kpis() {
      final tiles = <Widget>[
        KpiTile(
            wide: true,
            label: s.t("dash.orders"),
            value: "$total",
            caption: bi(s, "toutes semaines", "all weeks")),
        KpiTile(
            wide: true,
            label: s.t("dash.filtered"),
            value: "$filtered",
            active: true,
            caption: m.isLogistique
                ? (m.view == CalendarViewKind.delivInst
                    ? s.t("views.delivInst")
                    : m.view == CalendarViewKind.pickups
                        ? s.t("views.pickups")
                        : s.t("views.transfers"))
                : null,
            progress: total == 0 ? 0 : filtered / total),
        KpiTile(
            wide: true,
            label: s.t("dash.locations"),
            value: "$rentals",
            caption: bi(s, "cette semaine", "this week")),
        KpiTile(
            wide: true,
            label: s.t("dash.dateSel"),
            value: fmt.dayShort(m.selected),
            caption:
                bi(s, "cliquer un jour pour filtrer", "click a day to filter")),
      ];
      return Row(children: <Widget>[
        for (var i = 0; i < tiles.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 16),
          Expanded(child: tiles[i])
        ]
      ]);
    }

    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ...calendarBanners(m),
          kpis(),
          const SizedBox(height: 16),
          if (m.isLogistique) ...<Widget>[
            LogistiqueTabs(
                tall: true,
                selected: m.view,
                orders: m.all,
                onChanged: (v) =>
                    ref.read(logistiqueViewProvider.notifier).state = v),
            const SizedBox(height: 16),
          ],
          Container(
            decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(QuaiRadius.lg),
                border: Border.all(color: c.line)),
            clipBehavior: Clip.antiAlias,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
                    child: Row(children: <Widget>[
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(s.t("cal.weekly").toUpperCase(),
                                  style: quaiSans(c.sub,
                                      size: 11,
                                      height: 14,
                                      weight: FontWeight.w700,
                                      ls: .8)),
                              const SizedBox(height: 2),
                              Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: <Widget>[
                                    Flexible(
                                        child: Text(
                                            fmt.range(days.first, days.last),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            key: const Key("week-range"),
                                            style: quaiSans(c.ink,
                                                size: 24,
                                                height: 30,
                                                weight: FontWeight.w700))),
                                    const SizedBox(width: 8),
                                    Flexible(
                                        child: Text(
                                            "· ${fmt.count(weekOrders.length)}",
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: quaiSans(c.sub, size: 13))),
                                  ]),
                            ]),
                      ),
                      _SpanToggle(span: m.span == 14 ? 14 : 7, s: s),
                      const SizedBox(width: 12),
                      CircleNavButton(
                          buttonKey: const Key("week-prev"),
                          icon: Icons.chevron_left,
                          tooltip: s.t("cal.prev"),
                          onTap: () => shiftWeek(ref, m.span == 14 ? -2 : -1)),
                      const SizedBox(width: 8),
                      PillButton(
                          buttonKey: const Key("week-today"),
                          label: s.t("cal.thisWeek"),
                          onTap: () => goToday(ref)),
                      const SizedBox(width: 8),
                      CircleNavButton(
                          buttonKey: const Key("week-next"),
                          icon: Icons.chevron_right,
                          tooltip: s.t("cal.next"),
                          onTap: () => shiftWeek(ref, m.span == 14 ? 2 : 1)),
                    ]),
                  ),
                  Container(
                    color: c.field,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 10),
                    child: Row(children: <Widget>[
                      Text(s.t("cal.legend").toUpperCase(),
                          style: quaiSans(c.sub,
                              size: 10,
                              height: 12,
                              weight: FontWeight.w700,
                              ls: .8)),
                      const SizedBox(width: 14),
                      ServiceLegend(kinds: legendKinds(m)),
                    ]),
                  ),
                  for (var row = 0; row < days.length; row += 7)
                    _WeekGrid(
                        m: m,
                        days: days.sublist(row, row + 7),
                        fmt: fmt,
                        compact: compact),
                ]),
          ),
        ]);
  }
}

class _SpanToggle extends ConsumerWidget {
  const _SpanToggle({required this.span, required this.s});
  final int span;
  final Strings s;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.q;
    Widget seg(int v, String label) {
      final active = span == v;
      return GestureDetector(
        key: Key("span-$v"),
        onTap: () => ref.read(spanDaysProvider.notifier).state = v,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
              color: active ? c.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(QuaiRadius.full)),
          child: Text(label,
              style: quaiSans(active ? c.onPrimary : c.sub,
                  size: 13, weight: FontWeight.w700)),
        ),
      );
    }

    return Container(
      height: 36,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: c.field, borderRadius: BorderRadius.circular(QuaiRadius.full)),
      child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
        seg(7, s.t("cal.toggleWeek")),
        seg(14, s.t("cal.toggleBiweek"))
      ]),
    );
  }
}

/// Seven day columns. Cards sit in the column at full width (163 px at 1440 px).
class _WeekGrid extends ConsumerWidget {
  const _WeekGrid(
      {required this.m,
      required this.days,
      required this.fmt,
      required this.compact});
  final CalendarModel m;
  final List<DateTime> days;
  final CalFmt fmt;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.q;
    return IntrinsicHeight(
      child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final d in days)
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: sameDay(d, m.today) ? const Color(0xFFFCF3EE) : null,
                    border: Border(
                        top: BorderSide(color: c.line),
                        right: BorderSide(
                            color: c.line
                                .withValues(alpha: d == days.last ? 0 : 1))),
                  ),
                  constraints: const BoxConstraints(minHeight: 260),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _DayHeader(
                            day: d,
                            count: m.byDay[d]?.length ?? 0,
                            today: sameDay(d, m.today),
                            selected: sameDay(d, m.selected),
                            fmt: fmt),
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                              compact ? 4 : 8, 4, compact ? 4 : 8, 8),
                          child: Column(children: <Widget>[
                            for (final o in m.ordersOn(d))
                              OrderCard(order: o, now: m.now, dense: true)
                          ]),
                        ),
                      ]),
                ),
              ),
          ]),
    );
  }
}

class _DayHeader extends ConsumerWidget {
  const _DayHeader(
      {required this.day,
      required this.count,
      required this.today,
      required this.selected,
      required this.fmt});
  final DateTime day;
  final int count;
  final bool today;
  final bool selected;
  final CalFmt fmt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.q;
    return InkWell(
      key: Key("day-header-${day.month}-${day.day}"),
      onTap: () => ref.read(pickedDayProvider.notifier).state = day,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 6),
        child: Row(children: <Widget>[
          Text(fmt.dow(day),
              style: quaiSans(c.sub,
                  size: 10.5, height: 16, weight: FontWeight.w700, ls: .6)),
          const SizedBox(width: 6),
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: (today || selected) ? c.primary : Colors.transparent,
                shape: BoxShape.circle),
            child: Text("${day.day}",
                style: quaiSans((today || selected) ? c.onPrimary : c.ink,
                    size: 15, height: 18, weight: FontWeight.w700)),
          ),
          const Spacer(),
          if (count > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                  color: c.field,
                  borderRadius: BorderRadius.circular(QuaiRadius.full)),
              child: Text("$count",
                  style: quaiSans(c.sub,
                      size: 11, height: 14, weight: FontWeight.w700)),
            ),
        ]),
      ),
    );
  }
}
