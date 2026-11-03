import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:intl/intl.dart";

import "../i18n/i18n.dart";
import "../logic/order_windows.dart";
import "../state/providers.dart";

/// "Mes commandes" — upcoming only, 1 or 2 weeks.
class MyOrdersScreen extends ConsumerWidget {
  const MyOrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = StringsScope.of(context);
    final weeks = ref.watch(upcomingWeeksProvider);
    final asyncOrders = ref.watch(ordersProvider);
    final now = DateTime.now();
    final fmt = DateFormat.yMMMd(s.isFrench ? "fr_CA" : "en_CA");

    return Scaffold(
      appBar: AppBar(title: Text(s.t("dash.myOrders"))),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<int>(
              segments: <ButtonSegment<int>>[
                ButtonSegment<int>(value: 1, label: Text(s.t("cal.weekly"))),
                ButtonSegment<int>(value: 2, label: Text(s.t("cal.biweekly"))),
              ],
              selected: <int>{weeks},
              onSelectionChanged: (v) => ref.read(upcomingWeeksProvider.notifier).state = v.first,
            ),
          ),
          Expanded(
            child: asyncOrders.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(e.toString(), textAlign: TextAlign.center))),
              data: (orders) {
                final upcoming = orders.where((o) {
                  final d = OrderWindows.parseDate(o.date);
                  return d != null && OrderWindows.isUpcomingWithin(d, now, weeks);
                }).toList()
                  ..sort((a, b) => (a.date).compareTo(b.date));
                if (upcoming.isEmpty) {
                  return Center(child: Text(s.t("tbl.empty"), style: const TextStyle(color: Colors.black38)));
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: upcoming.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final o = upcoming[i];
                    final d = OrderWindows.parseDate(o.date);
                    return ListTile(
                      tileColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0x14000000))),
                      title: Text(o.soNum, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text([o.customer, o.serviceType].where((e) => (e ?? "").isNotEmpty).join(" · ")),
                      trailing: Text(d == null ? "" : fmt.format(d), style: const TextStyle(fontSize: 12)),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
