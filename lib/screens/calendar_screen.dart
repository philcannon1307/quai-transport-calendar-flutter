import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../api/orders_repository.dart";
import "../api/session.dart";
import "../data/carriers.dart";
import "../i18n/i18n.dart";
import "../logic/calendar_views.dart";
import "../logic/calendar_week.dart";
import "../logic/delivery_history.dart";
import "../logic/order_windows.dart";
import "../models/order.dart";
import "../state/calendar_state.dart";
import "../state/providers.dart";
import "../theme/quai_tokens.dart";
import "../widgets/announcement_banner.dart";
import "../widgets/bilingual.dart";
import "../widgets/brand_header.dart";
import "../widgets/calendar_common.dart";
import "../widgets/logistique_tabs.dart";
import "../widgets/order_card.dart";
import "../widgets/prep_widgets.dart";
import "../state/prep_providers.dart";
import "../widgets/receipt_sheet.dart";
import "calendar_wide.dart";

/// Everything a calendar layout needs, computed once per build.
class CalendarModel {
  CalendarModel({
    required this.strings,
    required this.carrierName,
    required this.isLogistique,
    required this.view,
    required this.load,
    required this.all,
    required this.shown,
    required this.merged,
    required this.now,
    required this.weekOffset,
    required this.picked,
    required this.span,
  })  : today = OrderWindows.businessDate(now),
        byDay = ordersByDay(merged) {
    final m = mondayOf(today);
    weekStart = DateTime(m.year, m.month, m.day + 7 * weekOffset);
    selected = effectiveSelectedDay(
        picked: picked, weekStart: weekStart, today: today);
  }

  final Strings strings;
  final String carrierName;
  final bool isLogistique;
  final CalendarViewKind view;
  final OrdersLoad? load;
  final List<Order> all;
  final List<Order> shown;
  final List<Order> merged;
  final DateTime now;
  final int weekOffset;
  final DateTime? picked;
  final int span;
  final DateTime today;
  final Map<DateTime, List<Order>> byDay;
  late final DateTime weekStart;
  late final DateTime selected;

  List<Order> ordersOn(DateTime d) =>
      sortedForDay(byDay[dateOnly(d)] ?? const <Order>[]);

  List<Order> ordersInRange(DateTime start, int days) => <Order>[
        for (final d in daysFrom(start, days)) ...(byDay[d] ?? const <Order>[])
      ];
}

void shiftWeek(WidgetRef ref, int delta) {
  final off = ref.read(weekOffsetProvider) + delta;
  ref.read(weekOffsetProvider.notifier).state = off;
  ref.read(pickedDayProvider.notifier).state = null;
  if (off < 0) {
    // Past weeks need delivery history; widen the range just enough.
    final needed = -off * 7 + 7;
    final want = needed <= 7 ? 7 : (needed <= 30 ? 30 : 365);
    if (ref.read(historyDaysProvider) < want)
      ref.read(historyDaysProvider.notifier).state = want;
  }
}

void goToday(WidgetRef ref) {
  ref.read(weekOffsetProvider.notifier).state = 0;
  ref.read(pickedDayProvider.notifier).state = null;
}

Future<void> signOutAndLeave(BuildContext context, WidgetRef ref) async {
  signOutNow(ref);
  await ref.read(urlLauncherProvider)(Uri.parse(kLogoutUrl));
  if (context.mounted)
    Navigator.of(context).pushNamedAndRemoveUntil("/", (_) => false);
}

/// Warnings above the calendar (expired session, unavailable sources).
List<Widget> calendarBanners(CalendarModel m) {
  final load = m.load;
  final failed = load?.failedTrucks ?? const <String>[];
  return <Widget>[
    const AnnouncementBanner(),
    if (load?.unauthorized ?? false)
      const MemoBanner(
          text:
              "Session expirée — reconnectez-vous. / Session expired — sign in again."),
    if (m.isLogistique &&
        m.view == CalendarViewKind.pickups &&
        (load?.middlewareUnavailable ?? false))
      const MemoBanner(
        text:
            "Ramassages indisponibles : la connexion à l'intergiciel n'est pas configurée. / "
            "Pick-ups unavailable: the middleware connection is not configured.",
      ),
    if (failed.isNotEmpty)
      MemoBanner(
        text:
            "Certains camions n'ont pas pu être chargés : ${failed.join(", ")} / "
            "Some trucks could not be loaded: ${failed.join(", ")}",
      ),
  ];
}

/// Service families present in a list, for the legend.
List<ServiceKind> legendKinds(CalendarModel m) {
  final kinds = <ServiceKind>[ServiceKind.install, ServiceKind.delivery];
  if (m.isLogistique && m.view == CalendarViewKind.pickups)
    kinds.add(ServiceKind.pickup);
  if (m.isLogistique && m.view == CalendarViewKind.transfers)
    kinds.add(ServiceKind.transfer);
  if (!m.isLogistique) {
    final present = m.shown.map(serviceKindOf).toSet();
    for (final k in <ServiceKind>[ServiceKind.pickup, ServiceKind.transfer]) {
      if (present.contains(k)) kinds.add(k);
    }
  }
  return kinds;
}

class CalendarScreen extends ConsumerWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = StringsScope.of(context);
    final asyncOrders = ref.watch(ordersProvider);
    final now = DateTime.now();
    final carrierName = ref.watch(currentCarrierProvider);
    final isLogistique = carrierName == kLogistique;
    final view = ref.watch(logistiqueViewProvider);
    final load = ref.watch(ordersLoadProvider).valueOrNull;
    final past = ref.watch(pastOrdersProvider).valueOrNull ?? const <Order>[];

    CalendarModel? model;
    final orders = asyncOrders.valueOrNull;
    if (orders != null) {
      final shown = isLogistique
          ? orders.where((o) => calendarView(o) == view).toList()
          : orders;
      model = CalendarModel(
        strings: s,
        carrierName: carrierName ?? "",
        isLogistique: isLogistique,
        view: view,
        load: load,
        all: orders,
        shown: shown,
        merged: mergeLiveAndPast(
            shown,
            isLogistique
                ? past.where((o) => calendarView(o) == view).toList()
                : past),
        now: now,
        weekOffset: ref.watch(weekOffsetProvider),
        picked: ref.watch(pickedDayProvider),
        span: ref.watch(spanDaysProvider),
      );
    }
    final status = asyncOrders.isLoading && model == null
        ? const Center(child: CircularProgressIndicator())
        : (asyncOrders.hasError && model == null
            ? CalMessage(text: asyncOrders.error.toString())
            : null);

    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= QuaiBreakpoints.phone;
      if (wide)
        return WideCalendar(model: model, status: status, width: box.maxWidth);
      return _PhoneCalendar(
          model: model, status: status, carrierName: carrierName ?? "");
    });
  }
}

// ------------------------------------------------------------------ phone

class _PhoneCalendar extends ConsumerWidget {
  const _PhoneCalendar(
      {required this.model, required this.status, required this.carrierName});
  final CalendarModel? model;
  final Widget? status;
  final String carrierName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.q;
    final s = StringsScope.of(context);
    final m = model;
    final total = m?.all.length ?? 0;
    final filtered = m?.shown.length ?? 0;
    final rentals =
        m == null ? 0 : m.ordersInRange(m.weekStart, 7).where(isRental).length;

    return Scaffold(
      backgroundColor: c.bg,
      body: Column(children: <Widget>[
        SizedBox(
          height: 150 + 62 - 38,
          child: Stack(children: <Widget>[
            BrandHeader(
              height: 150,
              padding: EdgeInsets.fromLTRB(
                  20, MediaQuery.of(context).padding.top + 12, 20, 0),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(children: <Widget>[
                      const BrandLogo(width: 124),
                      const Spacer(),
                      const LangToggle()
                    ]),
                    const SizedBox(height: 10),
                    Text(carrierName,
                        key: const Key("unit-name"),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: quaiSans(Colors.white,
                            size: 17, height: 22, weight: FontWeight.w700)),
                  ]),
            ),
            Positioned(
              left: 16,
              right: 16,
              top: 112,
              child: Row(children: <Widget>[
                Expanded(
                    child: KpiTile(label: s.t("dash.orders"), value: "$total")),
                const SizedBox(width: 10),
                Expanded(
                    child: KpiTile(
                        label: s.t("dash.filtered"),
                        value: "$filtered",
                        active: true)),
                const SizedBox(width: 10),
                Expanded(
                    child: KpiTile(
                        label: s.t("dash.locations"), value: "$rentals")),
              ]),
            ),
          ]),
        ),
        Expanded(
            child: m == null
                ? (status ?? const SizedBox.shrink())
                : _PhoneBody(m: m)),
        const _QuaiBottomNav(),
      ]),
    );
  }
}

class _PhoneBody extends ConsumerWidget {
  const _PhoneBody({required this.m});
  final CalendarModel m;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.q;
    final s = m.strings;
    final fmt = CalFmt(s);
    final weekDays = daysFrom(m.weekStart, 7);
    final weekOrders = m.ordersInRange(m.weekStart, 7);
    final selectedOrders = m.ordersOn(m.selected);
    final others = <DateTime>[
      for (final d in weekDays)
        if (!sameDay(d, m.selected) && (m.byDay[d]?.isNotEmpty ?? false)) d
    ];

    final prep = ref.watch(prepControllerProvider);
    return Stack(fit: StackFit.expand, children: <Widget>[
      // Not inside the list: the list drops its first rows when scrolled, the poll must keep running.
      Positioned(
          left: 0,
          top: 0,
          child: PrepSync(
              from: m.weekStart, to: m.weekStart.add(const Duration(days: 6)))),
      ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: <Widget>[
          ...calendarBanners(m),
          if (m.isLogistique) ...<Widget>[
            LogistiqueTabs(
                selected: m.view,
                orders: m.all,
                onChanged: (v) =>
                    ref.read(logistiqueViewProvider.notifier).state = v),
            const SizedBox(height: 12),
          ],
          Row(children: <Widget>[
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(fmt.range(weekDays.first, weekDays.last),
                        key: const Key("week-range"),
                        style: quaiSans(c.ink,
                            size: 20, height: 26, weight: FontWeight.w700)),
                    Text(
                        "${bi(s, "Vue hebdomadaire", "Weekly view")} · ${fmt.count(weekOrders.length)}",
                        style: quaiSans(c.sub, size: 13, height: 18)),
                  ]),
            ),
            CircleNavButton(
                buttonKey: const Key("week-prev"),
                icon: Icons.chevron_left,
                tooltip: s.t("cal.prev"),
                onTap: () => shiftWeek(ref, -1)),
            const SizedBox(width: 8),
            PillButton(
                buttonKey: const Key("week-today"),
                label: bi(s, "Auj.", "Today"),
                onTap: () => goToday(ref)),
            const SizedBox(width: 8),
            CircleNavButton(
                buttonKey: const Key("week-next"),
                icon: Icons.chevron_right,
                tooltip: s.t("cal.next"),
                onTap: () => shiftWeek(ref, 1)),
          ]),
          const SizedBox(height: 14),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v < -200) shiftWeek(ref, 1);
              if (v > 200) shiftWeek(ref, -1);
            },
            child: Row(children: <Widget>[
              for (final d in weekDays)
                Expanded(
                    child: _StripDay(
                        day: d,
                        orders: m.byDay[d] ?? const <Order>[],
                        prep: prep,
                        selected: sameDay(d, m.selected),
                        today: sameDay(d, m.today),
                        fmt: fmt)),
            ]),
          ),
          const SizedBox(height: 10),
          ServiceLegend(kinds: legendKinds(m)),
          const SizedBox(height: 16),
          Row(children: <Widget>[
            Expanded(
                child: Text(fmt.dayLong(m.selected),
                    key: const Key("selected-day"),
                    style: quaiSans(c.ink,
                        size: 17, height: 22, weight: FontWeight.w700))),
            Text(fmt.count(selectedOrders.length),
                style: quaiSans(c.sub, size: 13)),
          ]),
          PrepCounter(orders: selectedOrders),
          const SizedBox(height: 10),
          if (selectedOrders.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child:
                  Text(s.t("tbl.emptyDate"), style: quaiSerif(c.sub, size: 15)),
            )
          else
            for (final o in selectedOrders) OrderCard(order: o, now: m.now),
          for (final d in others)
            _CollapsedDay(
                key: ValueKey<DateTime>(d),
                day: d,
                orders: m.ordersOn(d),
                now: m.now,
                fmt: fmt),
        ],
      ),
    ]);
  }
}

/// One day of the strip: caps day name, bold number, up to 3 service dots. Selected = orange pill; today = orange dot.
class _StripDay extends ConsumerWidget {
  const _StripDay(
      {required this.day,
      required this.orders,
      required this.prep,
      required this.selected,
      required this.today,
      required this.fmt});
  final DateTime day;
  final List<Order> orders;
  final PrepModel prep;
  final bool selected;
  final bool today;
  final CalFmt fmt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.q;
    final dots = orders.take(3).toList();
    return GestureDetector(
      key: Key("strip-${day.day}"),
      behavior: HitTestBehavior.opaque,
      onTap: () => ref.read(pickedDayProvider.notifier).state = day,
      child: Container(
        height: 70,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
            color: selected ? c.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(QuaiRadius.lg)),
        // Stack.expand: the content fills the whole day cell and is centred in it (a loose Stack top-left-aligned
        // the column, which pushed the label/number/dots off-centre inside the pill).
        child: Stack(fit: StackFit.expand, children: <Widget>[
          Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Text(fmt.dow(day),
                    textAlign: TextAlign.center,
                    style: quaiSans(selected ? c.onPrimary : c.sub,
                        size: 10.5,
                        height: 12,
                        weight: FontWeight.w700,
                        ls: .6)),
                const SizedBox(height: 4),
                Text("${day.day}",
                    textAlign: TextAlign.center,
                    style: quaiSans(selected ? c.onPrimary : c.ink,
                        size: 18, height: 22, weight: FontWeight.w700)),
                const SizedBox(height: 5),
                SizedBox(
                  height: 6,
                  child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                    for (final o in dots)
                      Container(
                          key: prep.isPrepared(o)
                              ? Key("strip-dot-prepared-${o.soNum}")
                              : null,
                          margin: const EdgeInsets.symmetric(horizontal: 1.5),
                          width: 6,
                          height: 6,
                          // Prepared = green (on the orange selected pill: white with a green ring).
                          decoration: BoxDecoration(
                              color: prep.isPrepared(o)
                                  ? (selected ? c.onPrimary : c.confirmed)
                                  : (selected
                                      ? c.onPrimary
                                      : serviceColor(c, serviceKindOf(o))),
                              border: prep.isPrepared(o) && selected
                                  ? Border.all(color: c.confirmed, width: 2)
                                  : null,
                              shape: BoxShape.circle)),
                  ]),
                ),
              ]),
          if (today)
            Positioned(
                top: 5,
                right: 6,
                child: Container(
                    key: const Key("today-dot"),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                        color: selected ? c.onPrimary : c.primary,
                        shape: BoxShape.circle))),
        ]),
      ),
    );
  }
}

/// Collapsed row for another day of the week; taps expand it in place (no horizontal scroll anywhere).
class _CollapsedDay extends StatefulWidget {
  const _CollapsedDay(
      {super.key,
      required this.day,
      required this.orders,
      required this.now,
      required this.fmt});
  final DateTime day;
  final List<Order> orders;
  final DateTime now;
  final CalFmt fmt;

  @override
  State<_CollapsedDay> createState() => _CollapsedDayState();
}

class _CollapsedDayState extends State<_CollapsedDay> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Material(
              color: c.surface,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(QuaiRadius.md),
                  side: BorderSide(color: c.line)),
              child: InkWell(
                key: Key("other-day-${widget.day.day}"),
                customBorder: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(QuaiRadius.md)),
                onTap: () => setState(() => _open = !_open),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  child: Row(children: <Widget>[
                    Text(widget.fmt.dayShort(widget.day),
                        style:
                            quaiSans(c.ink, size: 15, weight: FontWeight.w700)),
                    const Spacer(),
                    Flexible(
                        child: Text(
                            widget.fmt.countWithCancelled(widget.orders),
                            overflow: TextOverflow.ellipsis,
                            style: quaiSans(c.sub, size: 13))),
                    const SizedBox(width: 6),
                    Icon(_open ? Icons.expand_less : Icons.chevron_right,
                        size: 18, color: c.faint),
                  ]),
                ),
              ),
            ),
            if (_open) ...<Widget>[
              const SizedBox(height: 10),
              for (final o in widget.orders)
                OrderCard(order: o, now: widget.now)
            ],
          ]),
    );
  }
}

// ------------------------------------------------------------------ bottom nav + account sheet

class _QuaiBottomNav extends ConsumerWidget {
  const _QuaiBottomNav();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.q;
    final s = StringsScope.of(context);
    Widget item(String keyName, IconData icon, String label, bool active,
            VoidCallback onTap) =>
        Expanded(
          child: GestureDetector(
            key: Key(keyName),
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Container(
                    width: 56,
                    height: 32,
                    decoration: BoxDecoration(
                        color: active ? c.primarySoft : Colors.transparent,
                        borderRadius: BorderRadius.circular(QuaiRadius.full)),
                    child: Icon(icon,
                        size: 22, color: active ? c.primaryInk : c.sub),
                  ),
                  const SizedBox(height: 4),
                  Text(label,
                      style: quaiSans(active ? c.primaryInk : c.sub,
                          size: 12, height: 16, weight: FontWeight.w700)),
                ]),
          ),
        );
    return Container(
      height: QuaiSpace.bottomNav - 20 + MediaQuery.of(context).padding.bottom,
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
          color: c.surface, border: Border(top: BorderSide(color: c.line))),
      child: Row(children: <Widget>[
        item("nav-calendar", Icons.calendar_view_week_outlined,
            bi(s, "Calendrier", "Calendar"), true, () {}),
        item(
            "nav-orders",
            Icons.view_list_outlined,
            bi(s, "Commandes", "Orders"),
            false,
            () => Navigator.of(context).pushNamed("/my-orders")),
        item("nav-account", Icons.person_outline, bi(s, "Compte", "Account"),
            false, () => showAccountSheet(context, ref)),
      ]),
    );
  }
}

/// Compte: refresh, receipts / BOL, history range and sign-out (they no longer live in the header on phone).
Future<void> showAccountSheet(BuildContext context, WidgetRef ref) {
  final c = context.q;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.surface,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(QuaiRadius.sheet))),
    builder: (sheetContext) => Consumer(builder: (ctx, ref2, _) {
      final s = StringsScope.of(ctx);
      final name = ref2.watch(currentCarrierProvider);
      final receipt = receiptButtonFor(name,
          isSuperUser: ref2.watch(sessionProvider).isSuperUser);
      final history = ref2.watch(historyDaysProvider);
      Widget tile(
              String key, IconData icon, String label, VoidCallback onTap) =>
          ListTile(
            key: Key(key),
            leading: Icon(icon, color: c.ink),
            title: Text(label,
                style: quaiSans(c.ink, size: 15, weight: FontWeight.w700)),
            onTap: onTap,
          );
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
            Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(name ?? "", style: quaiSans(c.sub, size: 13)))),
            tile("account-refresh", Icons.refresh, s.t("common.refresh"), () {
              Navigator.of(sheetContext).pop();
              ref.invalidate(ordersLoadProvider);
            }),
            if (receipt.show)
              tile(
                  "receipt-button",
                  receipt.bol
                      ? Icons.local_shipping_outlined
                      : Icons.receipt_long_outlined,
                  s.t(receipt.bol ? "bol.button" : "receipts.button"), () {
                Navigator.of(sheetContext).pop();
                showReceiptSheet(context, bol: receipt.bol);
              }),
            ListTile(
              leading: Icon(Icons.history, color: c.ink),
              title: Text(bi(s, "Historique", "History"),
                  style: quaiSans(c.ink, size: 15, weight: FontWeight.w700)),
              trailing: DropdownButton<int>(
                key: const Key("history-range"),
                value: history,
                underline: const SizedBox.shrink(),
                items: <DropdownMenuItem<int>>[
                  for (final d in kHistoryRanges)
                    DropdownMenuItem<int>(
                        value: d,
                        child: Text(d == 0
                            ? bi(s, "Aucun", "None")
                            : "${bi(s, "Passé", "Past")} $d ${bi(s, "j", "d")}")),
                ],
                onChanged: (v) =>
                    ref.read(historyDaysProvider.notifier).state = v ?? 0,
              ),
            ),
            tile("logout-button", Icons.logout, s.t("common.logout"), () {
              Navigator.of(sheetContext).pop();
              signOutAndLeave(context, ref);
            }),
          ]),
        ),
      );
    }),
  );
}
