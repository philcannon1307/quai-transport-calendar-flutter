import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../i18n/i18n.dart";
import "../state/providers.dart";
import "../theme/quai_tokens.dart";
import "bilingual.dart";

/// "Données à jour il y a N min" + Refresh, shown on the Admin screen while the orders come
/// from the server-side aggregate. Shows nothing when the screen is on the slow fallback path.
class AdminAggregateBar extends ConsumerWidget {
  const AdminAggregateBar({super.key});

  static String ageText(Strings s, DateTime? generatedAt, DateTime now) {
    if (generatedAt == null) return bi(s, "Données en préparation", "Data is being prepared");
    final mins = now.difference(generatedAt).inMinutes;
    if (mins < 1) return bi(s, "Données à jour à l'instant", "Updated just now");
    return bi(s, "Données à jour il y a $mins min", "Updated $mins min ago");
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = StringsScope.of(context);
    final agg = ref.watch(adminAggregateProvider).valueOrNull;
    if (agg == null) return const SizedBox.shrink();
    final busy = ref.watch(adminRefreshingProvider) || agg.refreshing;
    final c = context.q;
    final age = ageText(s, agg.generatedAt, DateTime.now());
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              busy ? "$age · " + bi(s, "mise à jour en cours…", "refreshing…") : age,
              key: const Key("admin-aggregate-age"),
              style: quaiSans(c.sub, size: 12, height: 17, weight: FontWeight.w600),
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: c.primaryInk, minimumSize: const Size(0, QuaiSpace.tapMin)),
            key: const Key("admin-aggregate-refresh"),
            onPressed: busy ? null : () => unawaited(refreshAdminAggregate(ProviderScope.containerOf(context))),
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(bi(s, "Actualiser", "Refresh")),
          ),
        ],
      ),
    );
  }
}
