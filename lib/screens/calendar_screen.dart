import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:intl/intl.dart";

import "../i18n/i18n.dart";
import "../logic/calendar_views.dart";
import "../logic/order_windows.dart";
import "../models/order.dart";
import "../state/providers.dart";
import "../theme.dart";
import "../data/carriers.dart";
import "../widgets/contact_links.dart";
import "../widgets/logistique_tabs.dart";
import "../logic/delivery_history.dart";
import "../widgets/adjustment_sheet.dart";
import "../widgets/announcement_banner.dart";
import "../widgets/bilingual.dart";
import "../widgets/receipt_sheet.dart";
import "../api/session.dart";
import "ticket_sheet.dart";

class CalendarScreen extends ConsumerWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = StringsScope.of(context);
    final span = ref.watch(spanDaysProvider);
    final asyncOrders = ref.watch(ordersProvider);
    final now = DateTime.now();
    final isLogistique = ref.watch(currentCarrierProvider) == kLogistique;
    final view = ref.watch(logistiqueViewProvider);
    final load = ref.watch(ordersLoadProvider).valueOrNull;
    final carrierName = ref.watch(currentCarrierProvider);
    final receipt = receiptButtonFor(carrierName, isSuperUser: ref.watch(sessionProvider).isSuperUser);
    final historyDays = ref.watch(historyDaysProvider);
    final past = ref.watch(pastOrdersProvider).valueOrNull ?? const <Order>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(s.t("brand.name")),
        actions: <Widget>[
          if (receipt.show)
            IconButton(
              key: const Key("receipt-button"),
              tooltip: s.t(receipt.bol ? "bol.button" : "receipts.button"),
              icon: Icon(receipt.bol ? Icons.local_shipping_outlined : Icons.receipt_long_outlined),
              onPressed: () => showReceiptSheet(context, bol: receipt.bol),
            ),
          IconButton(
            tooltip: s.t("dash.myOrders"),
            icon: const Icon(Icons.assignment_outlined),
            onPressed: () => Navigator.of(context).pushNamed("/my-orders"),
          ),
          IconButton(
            key: const Key("logout-button"),
            tooltip: s.t("common.logout"),
            icon: const Icon(Icons.logout),
            onPressed: () async {
              signOutNow(ref);
              await ref.read(urlLauncherProvider)(Uri.parse(kLogoutUrl));
              if (context.mounted) Navigator.of(context).pushNamedAndRemoveUntil("/", (_) => false);
            },
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          const AnnouncementBanner(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                SegmentedButton<int>(
                  segments: <ButtonSegment<int>>[
                    ButtonSegment<int>(value: 7, label: Text(s.t("cal.weekly"))),
                    ButtonSegment<int>(value: 14, label: Text(s.t("cal.biweekly"))),
                  ],
                  selected: <int>{span},
                  onSelectionChanged: (v) => ref.read(spanDaysProvider.notifier).state = v.first,
                ),
                const SizedBox(width: 10),
                DropdownButton<int>(
                  key: const Key("history-range"),
                  value: historyDays,
                  underline: const SizedBox.shrink(),
                  items: <DropdownMenuItem<int>>[
                    for (final d in kHistoryRanges)
                      DropdownMenuItem<int>(
                        value: d,
                        child: Text(d == 0 ? bi(s, "Historique", "History") : "${bi(s, "Passé", "Past")} $d ${bi(s, "j", "d")}"),
                      ),
                  ],
                  onChanged: (v) => ref.read(historyDaysProvider.notifier).state = v ?? 0,
                ),
              ],
            ),
          ),
          Expanded(
            child: asyncOrders.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => _Message(text: e.toString()),
              data: (orders) {
                final shown = isLogistique ? orders.where((o) => calendarView(o) == view).toList() : orders;
                final failed = load?.failedTrucks ?? const <String>[];
                return Column(
                  children: <Widget>[
                    if (isLogistique)
                      LogistiqueTabs(
                        selected: view,
                        orders: orders,
                        onChanged: (v) => ref.read(logistiqueViewProvider.notifier).state = v,
                      ),
                    if (load?.unauthorized ?? false)
                      const _Banner(text: "Session expirée — reconnectez-vous. / Session expired — sign in again."),
                    if (isLogistique && view == CalendarViewKind.pickups && (load?.middlewareUnavailable ?? false))
                      const _Banner(
                        text: "Ramassages indisponibles : la connexion à l'intergiciel n'est pas configurée. / "
                            "Pick-ups unavailable: the middleware connection is not configured.",
                      ),
                    if (failed.isNotEmpty)
                      _Banner(
                        text: "Certains camions n'ont pas pu être chargés : ${failed.join(", ")} / "
                            "Some trucks could not be loaded: ${failed.join(", ")}",
                      ),
                    Expanded(
                      child: _DayStack(
                        days: <DateTime>[..._pastDays(past, now), ...OrderWindows.days(now, span)],
                        orders: mergeLiveAndPast(shown, isLogistique ? past.where((o) => calendarView(o) == view).toList() : past),
                        now: now,
                        strings: s,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Mobile-first vertical stack: one section per day, cards underneath.
class _DayStack extends StatelessWidget {
  const _DayStack({required this.days, required this.orders, required this.now, required this.strings});
  final List<DateTime> days;
  final List<Order> orders;
  final DateTime now;
  final Strings strings;

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat.MMMEd(strings.isFrench ? "fr_CA" : "en_CA");
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      itemCount: days.length,
      itemBuilder: (context, i) {
        final day = days[i];
        final dayOrders = orders.where((o) {
          final d = OrderWindows.parseDate(o.date);
          return d != null && d.year == day.year && d.month == day.month && d.day == day.day;
        }).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 6),
              child: Text(fmt.format(day), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            ),
            if (dayOrders.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(strings.t("tbl.emptyDate"), style: const TextStyle(color: Colors.black38, fontSize: 12)),
              )
            else
              ...dayOrders.map((o) => _OrderCard(order: o, now: now, strings: strings)),
          ],
        );
      },
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.now, required this.strings});
  final Order order;
  final DateTime now;
  final Strings strings;

  Color _accent() {
    final d = OrderWindows.parseDate(order.date);
    if (d != null && OrderWindows.isPast(d, now)) return CardPalette.past;
    switch (calendarView(order)) {
      case CalendarViewKind.transfers:
        return CardPalette.transfers;
      case CalendarViewKind.pickups:
        return CardPalette.pickups;
      case CalendarViewKind.delivInst:
        return CardPalette.delivInst;
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent();
    final isPast = accent == CardPalette.past;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isPast ? const Color(0xFFFDECEC) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isPast ? CardPalette.past.withValues(alpha: 0.5) : const Color(0x14000000)),
      ),
      // IntrinsicHeight: lets the accent stripe match the card's height without
      // CrossAxisAlignment.stretch, which has no bounded height here.
      child: InkWell(
        key: Key("card-${order.soNum}"),
        borderRadius: BorderRadius.circular(12),
        onTap: () => showTicketSheet(context, order.soNum),
        child: IntrinsicHeight(
        child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(width: 5, decoration: BoxDecoration(color: accent, borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)))),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(child: Text(order.soNum, style: const TextStyle(fontWeight: FontWeight.w700))),
                      InkWell(
                        key: Key("report-${order.soNum}"),
                        onTap: () => showAdjustmentSheet(context, order),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          child: Row(children: <Widget>[
                            const Icon(Icons.flag_outlined, size: 14, color: Colors.black54),
                            const SizedBox(width: 3),
                            Text(bi(strings, "Signaler", "Report"), style: const TextStyle(fontSize: 11, color: Colors.black54)),
                          ]),
                        ),
                      ),
                      if (order.isTransfer)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: CardPalette.transfers.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
                          child: const Text("TO", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
                        ),
                    ],
                  ),
                  if ((order.customer ?? "").isNotEmpty)
                    Padding(padding: const EdgeInsets.only(top: 2), child: Text(order.customer!, style: const TextStyle(fontSize: 13))),
                  if ((order.serviceType ?? "").isNotEmpty)
                    Padding(padding: const EdgeInsets.only(top: 2), child: Text(order.serviceType!, style: const TextStyle(fontSize: 11, color: Colors.black54))),
                  if (!order.isTransfer)
                    Padding(padding: const EdgeInsets.only(top: 6), child: ContactLinks(soNum: order.soNum)),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF4E5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFF5C27A)),
        ),
        child: Text(text, style: const TextStyle(fontSize: 12)),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Colors.black54))),
      );
}

/// Days (oldest first) that have at least one past delivery, strictly before today.
List<DateTime> _pastDays(List<Order> past, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final seen = <DateTime>{};
  for (final o in past) {
    final d = OrderWindows.parseDate(o.date);
    if (d == null) continue;
    final day = DateTime(d.year, d.month, d.day);
    if (day.isBefore(today)) seen.add(day);
  }
  return seen.toList()..sort();
}
