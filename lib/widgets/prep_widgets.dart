import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../api/order_change_service.dart";
import "../i18n/i18n.dart";
import "../logic/prep_state.dart";
import "../models/order.dart";
import "../state/prep_providers.dart";
import "../theme/quai_tokens.dart";
import "bilingual.dart";

/// Plain-words reason a change of the prepared state failed.
String prepErrorText(Strings s, Object e) {
  switch (changeErrorKey(e)) {
    case "forbidden":
      return bi(s, "Seule la logistique peut changer cet état.", "Only logistics can change this state.");
    case "session":
      return bi(s, "Session expirée — reconnectez-vous.", "Session expired — sign in again.");
    case "too_many":
      return bi(s, "Trop de changements. Réessayez dans un instant.", "Too many changes. Try again in a moment.");
    case "network":
      return bi(s, "Réseau indisponible — l'état n'a pas été enregistré.", "Network unavailable — the state was not saved.");
    case "not_configured":
      return bi(s, "Le serveur n'est pas configuré.", "The server is not configured.");
    default:
      return bi(s, "Impossible d'enregistrer. Réessayez.", "Could not save. Try again.");
  }
}

/// The 52 px "À préparer / Préparé" pill. One tap toggles (no dialog) and offers a 6 s UNDO.
/// Logistics + SuperUser can tap; everybody else only sees a read-only "Préparé" pill, and only once it is prepared.
class PrepButton extends ConsumerWidget {
  const PrepButton({super.key, required this.order, this.dense = false});
  final Order order;
  final bool dense;

  /// Whether this order will show a button at all (so a card can lay itself out accordingly).
  static bool visibleFor(WidgetRef ref, Order order) {
    if (!ref.watch(prepServiceProvider).configured || !needsPrep(order)) return false;
    return sessionCanPrepare(ref) || ref.watch(prepControllerProvider).isPrepared(order);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!visibleFor(ref, order)) return const SizedBox.shrink();
    final s = StringsScope.of(context);
    final entry = ref.watch(prepControllerProvider).of(order);
    final prepared = entry?.prepared == true;
    final staff = sessionCanPrepare(ref);
    return _PrepPill(
      key: Key((staff ? "prep-" : "prep-ro-") + order.soNum),
      prepared: prepared,
      stamp: prepared && entry != null ? prepStamp(entry, DateTime.now()) : "",
      dense: dense,
      s: s,
      onTap: staff ? () => _toggle(context, ref, !prepared) : null,
    );
  }

  void _toggle(BuildContext context, WidgetRef ref, bool target) {
    final s = StringsScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ctrl = ref.read(prepControllerProvider.notifier);
    messenger.hideCurrentSnackBar();
    final saving = ctrl.setPrepared(order, target, now: DateTime.now());
    messenger.showSnackBar(SnackBar(
      key: const Key("prep-snackbar"),
      duration: const Duration(seconds: 6),
      content: Text(target
          ? bi(s, "${order.soNum} marquée préparée", "${order.soNum} marked prepared")
          : bi(s, "${order.soNum} remise à préparer", "${order.soNum} back to “to prepare”")),
      action: SnackBarAction(
        label: bi(s, "ANNULER", "UNDO"),
        onPressed: () {
          ctrl.setPrepared(order, !target, now: DateTime.now()).catchError((Object e) {
            messenger.showSnackBar(SnackBar(content: Text(prepErrorText(s, e))));
          });
        },
      ),
    ));
    saving.catchError((Object e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        key: const Key("prep-error"),
        duration: const Duration(seconds: 6),
        content: Text(prepErrorText(s, e)),
      ));
    });
  }
}

class _PrepPill extends StatelessWidget {
  const _PrepPill({super.key, required this.prepared, required this.stamp, required this.dense, required this.s, this.onTap});
  final bool prepared;
  final String stamp;
  final bool dense;
  final Strings s;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.q;
    final label = prepared ? bi(s, "Préparé", "Prepared") : bi(s, "À préparer", "To prepare");
    final fg = prepared ? Colors.white : c.ink;
    final pill = Material(
      color: prepared ? c.confirmed : c.surface,
      shape: StadiumBorder(side: BorderSide(color: prepared ? c.confirmed : c.ink, width: 1.5)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Container(
          height: dense ? 44 : 52,
          padding: EdgeInsets.symmetric(horizontal: dense ? 10 : 16),
          alignment: Alignment.center,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: <Widget>[
            Icon(prepared ? Icons.check_circle : Icons.radio_button_unchecked, size: dense ? 18 : 22, color: fg),
            const SizedBox(width: 8),
            Flexible(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(label,
                    key: const Key("prep-label"),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: quaiSans(fg, size: dense ? 13 : 15, height: 18, weight: FontWeight.w700)),
                if (prepared && stamp.isNotEmpty)
                  Text(stamp,
                      key: const Key("prep-stamp"),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: quaiSans(fg.withValues(alpha: 0.9), size: dense ? 10.5 : 12, height: 14)),
              ]),
            ),
          ]),
        ),
      ),
    );
    return Semantics(button: onTap != null, label: label + (stamp.isEmpty ? "" : " — " + stamp), child: pill);
  }
}

/// "3/7 préparées" + a green progress bar. Hidden when nothing on the day needs preparing or the server is not configured.
class PrepCounter extends ConsumerWidget {
  const PrepCounter({super.key, required this.orders});
  final List<Order> orders;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(prepServiceProvider).configured) return const SizedBox.shrink();
    final count = prepCount(orders, ref.watch(prepControllerProvider).entries);
    if (count.total == 0) return const SizedBox.shrink();
    final c = context.q;
    final s = StringsScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text("${count.done}/${count.total} ${bi(s, count.total == 1 ? "préparée" : "préparées", "prepared")}",
            key: const Key("prep-counter"),
            style: quaiSans(count.complete ? c.confirmed : c.sub, size: 13, height: 18, weight: FontWeight.w700)),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(QuaiRadius.full),
          child: LinearProgressIndicator(
            key: const Key("prep-progress"),
            value: count.fraction,
            minHeight: 6,
            backgroundColor: c.confirmedBg,
            color: c.confirmed,
          ),
        ),
      ]),
    );
  }
}

/// Keeps the prepared states of a date window fresh: loads on open, when the window changes, when the app comes back
/// to the foreground, and every 30 s while mounted. Draws nothing, and does nothing when the server is not configured.
class PrepSync extends ConsumerStatefulWidget {
  const PrepSync({super.key, required this.from, required this.to, this.interval = const Duration(seconds: 30)});
  final DateTime from;
  final DateTime to;
  final Duration interval;

  @override
  ConsumerState<PrepSync> createState() => _PrepSyncState();
}

class _PrepSyncState extends ConsumerState<PrepSync> with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (ref.read(prepServiceProvider).configured) {
      _timer = Timer.periodic(widget.interval, (_) => _refresh());
      // After the first frame: a provider must not be modified while the tree is building.
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }
  }

  @override
  void didUpdateWidget(PrepSync old) {
    super.didUpdateWidget(old);
    if (isoDay(old.from) != isoDay(widget.from) || isoDay(old.to) != isoDay(widget.to)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _refresh() {
    if (!mounted) return;
    ref.read(prepControllerProvider.notifier).refresh(isoDay(widget.from), isoDay(widget.to));
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
