import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../api/order_change_service.dart";
import "../i18n/i18n.dart";
import "../logic/order_change.dart";
import "../models/order.dart";
import "../state/order_change_providers.dart";
import "bilingual.dart";

const Color _kChangedFg = Color(0xFF92400E);
const Color _kChangedBg = Color(0xFFFEF3C7);

/// "Modifié / Changed" chip. [changed] true = show it (used where the answer is already known).
class ChangedChip extends StatelessWidget {
  const ChangedChip({super.key, this.count});
  final int? count;

  @override
  Widget build(BuildContext context) {
    final s = StringsScope.of(context);
    final n = (count ?? 0) > 1 ? " ×" + count.toString() : "";
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: _kChangedBg, borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0xFFF59E0B))),
      child: Text(bi(s, "Modifié", "Changed") + n, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _kChangedFg)),
    );
  }
}

/// Badge for calendar cards: shown only when the server says this order has saved changes.
class OrderChangedBadge extends ConsumerWidget {
  const OrderChangedBadge({super.key, required this.orderNum});
  final String orderNum;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(changedOrdersProvider).valueOrNull?[orderNum.trim().toUpperCase()];
    if (info == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: KeyedSubtree(key: Key("changed-badge-" + orderNum), child: ChangedChip(count: info.count)),
    );
  }
}

/// Badge on the ticket itself (reads that one order's history).
class TicketChangedBadge extends ConsumerWidget {
  const TicketChangedBadge({super.key, required this.orderNum});
  final String orderNum;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(orderChangesProvider(orderNum)).valueOrNull;
    if (groups == null || groups.isEmpty) return const SizedBox.shrink();
    return KeyedSubtree(key: const Key("ticket-changed-badge"), child: ChangedChip(count: groups.length));
  }
}

String _errorText(Strings s, Object e) {
  switch (changeErrorKey(e)) {
    case "not_configured":
      return bi(s, "Le serveur n'est pas configuré.", "The server is not configured.");
    case "session":
      return bi(s, "Session expirée — reconnectez-vous.", "Session expired — sign in again.");
    case "forbidden":
      return bi(s, "Cette commande n'est pas la vôtre : vous ne pouvez pas la modifier.", "This is not your order: you cannot change it.");
    case "too_many":
      return bi(s, "Trop de modifications. Réessayez dans quelques minutes.", "Too many changes. Try again in a few minutes.");
    case "invalid":
      return bi(s, "Modification refusée — vérifiez les champs.", "Change refused — check the fields.");
    case "network":
      return bi(s, "Réseau indisponible.", "Network unavailable.");
    default:
      return bi(s, "Une erreur est survenue. Réessayez.", "Something went wrong. Try again.");
  }
}

Future<bool?> showOrderChangeScreen(BuildContext context, Order order) {
  return Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(fullscreenDialog: true, builder: (_) => OrderChangeScreen(order: order)),
  );
}

/// Edit form -> "who will be notified" confirmation -> save. FR / EN labels together, like the rest of the app.
class OrderChangeScreen extends ConsumerStatefulWidget {
  const OrderChangeScreen({super.key, required this.order});
  final Order order;

  @override
  ConsumerState<OrderChangeScreen> createState() => _OrderChangeScreenState();
}

class _ItemCtl {
  final TextEditingController item = TextEditingController();
  final TextEditingController from = TextEditingController();
  final TextEditingController to = TextEditingController();
  ItemEdit toEdit() => ItemEdit(item: item.text, from: from.text, to: to.text);
  void dispose() {
    item.dispose();
    from.dispose();
    to.dispose();
  }
}

class _OrderChangeScreenState extends ConsumerState<OrderChangeScreen> {
  late final Map<String, String> _before = currentValues(widget.order);
  late final Map<String, TextEditingController> _ctl = <String, TextEditingController>{
    for (final f in fieldsFor(widget.order)) f.key: TextEditingController(text: _before[f.key] ?? ""),
  };
  final TextEditingController _reason = TextEditingController();
  final List<_ItemCtl> _items = <_ItemCtl>[];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    for (final i in _items) {
      i.dispose();
    }
    _reason.dispose();
    super.dispose();
  }

  List<FieldChange> _changes() => diffChanges(
        _before,
        <String, String>{for (final e in _ctl.entries) e.key: e.value.text},
        items: _items.map((i) => i.toEdit()).toList(),
      );

  Future<void> _continue() async {
    final s = StringsScope.of(context);
    final changes = _changes();
    if (changes.isEmpty) {
      setState(() => _error = bi(s, "Aucune modification à enregistrer.", "Nothing has been changed."));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final service = ref.read(orderChangeServiceProvider);
    PreviewResult preview;
    try {
      preview = await service.preview(widget.order);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _errorText(s, e);
      });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmChangeDialog(order: widget.order, changes: changes, preview: preview),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await service.submit(widget.order, changes, reason: _reason.text);
      ref.invalidate(orderChangesProvider(widget.order.soNum));
      ref.invalidate(changedOrdersProvider);
      if (!mounted) return;
      final msg = res.emailFailed
          ? bi(s, "Modification enregistrée, mais l'avis par courriel n'a pas pu être envoyé.", "Change saved, but the e-mail notice could not be sent.")
          : res.testMode
              ? bi(s, "Modification enregistrée. Avis envoyé en mode TEST (adresse de test seulement).", "Change saved. Notice sent in TEST mode (test address only).")
              : bi(s, "Modification enregistrée et avis envoyé.", "Change saved and notice sent.");
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _errorText(s, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = StringsScope.of(context);
    final fields = fieldsFor(widget.order);
    return Scaffold(
      appBar: AppBar(
        title: Text(bi(s, "Modifier la commande ", "Change order ") + widget.order.soNum, key: const Key("chg-title")),
        actions: <Widget>[
          TextButton(key: const Key("chg-cancel"), onPressed: _busy ? null : () => Navigator.of(context).maybePop(), child: Text(bi(s, "Annuler", "Cancel"))),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            bi(s, "Les modifications sont enregistrées dans l'application et les divisions concernées sont avisées par courriel. NetSuite n'est pas modifié.",
                "Changes are saved in the app and the divisions concerned are notified by e-mail. NetSuite is not changed."),
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 12),
          for (final f in fields)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                key: Key("chg-field-" + f.key),
                controller: _ctl[f.key],
                enabled: !_busy,
                decoration: InputDecoration(labelText: bi(s, f.fr, f.en), border: const OutlineInputBorder(), isDense: true),
              ),
            ),
          const SizedBox(height: 4),
          Text(bi(s, "Articles (quantités)", "Items (quantities)"), style: const TextStyle(fontWeight: FontWeight.w700)),
          for (var i = 0; i < _items.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: <Widget>[
                Expanded(flex: 3, child: TextField(key: Key("chg-item-$i"), controller: _items[i].item, enabled: !_busy, decoration: InputDecoration(labelText: bi(s, "Article", "Item"), border: const OutlineInputBorder(), isDense: true))),
                const SizedBox(width: 6),
                Expanded(flex: 2, child: TextField(key: Key("chg-from-$i"), controller: _items[i].from, enabled: !_busy, decoration: InputDecoration(labelText: bi(s, "Avant", "Before"), border: const OutlineInputBorder(), isDense: true))),
                const SizedBox(width: 6),
                Expanded(flex: 2, child: TextField(key: Key("chg-to-$i"), controller: _items[i].to, enabled: !_busy, decoration: InputDecoration(labelText: bi(s, "Après", "After"), border: const OutlineInputBorder(), isDense: true))),
                IconButton(
                  key: Key("chg-item-remove-$i"),
                  onPressed: _busy ? null : () => setState(() => _items.removeAt(i).dispose()),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ]),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key("chg-add-item"),
              onPressed: _busy || _items.length >= 20 ? null : () => setState(() => _items.add(_ItemCtl())),
              icon: const Icon(Icons.add, size: 18),
              label: Text(bi(s, "Ajouter un article", "Add an item")),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key("chg-reason"),
            controller: _reason,
            enabled: !_busy,
            maxLines: 2,
            decoration: InputDecoration(labelText: bi(s, "Raison (facultatif)", "Reason (optional)"), border: const OutlineInputBorder(), isDense: true),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, key: const Key("chg-error"), style: const TextStyle(color: Colors.red)),
            ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key("chg-continue"),
            onPressed: _busy ? null : _continue,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(bi(s, "Continuer", "Continue")),
          ),
        ],
        ),
      ),
    );
  }
}

/// Last step before saving: what changes and exactly who will be e-mailed.
class ConfirmChangeDialog extends StatelessWidget {
  const ConfirmChangeDialog({super.key, required this.order, required this.changes, required this.preview});
  final Order order;
  final List<FieldChange> changes;
  final PreviewResult preview;

  @override
  Widget build(BuildContext context) {
    final s = StringsScope.of(context);
    final fr = s.isFrench;
    return AlertDialog(
      key: const Key("chg-confirm-dialog"),
      title: Text(bi(s, "Confirmer la modification", "Confirm the change")),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(order.soNum, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            for (final c in changes)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(c.label(french: fr) + " : " + (c.oldValue.isEmpty ? "—" : c.oldValue) + " → " + (c.newValue.isEmpty ? "—" : c.newValue), style: const TextStyle(fontSize: 13)),
              ),
            const Divider(),
            Text(bi(s, "Seront avisés par courriel :", "Will be notified by e-mail:"), style: const TextStyle(fontWeight: FontWeight.w700)),
            for (final r in preview.recipients)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  (r.email.isNotEmpty ? r.email + " — " : (r.division ?? "") .isNotEmpty ? r.division! + " — " : "") + r.roles.map((x) => roleLabel(x, french: fr)).join(", "),
                  key: Key("chg-recipient-" + (r.email.isNotEmpty ? r.email : r.roles.join("+"))),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            if (preview.unresolved.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  bi(s, "Division introuvable pour : ", "Division not found for: ") + preview.unresolved.join(", "),
                  key: const Key("chg-unresolved"),
                  style: const TextStyle(fontSize: 12, color: Colors.deepOrange),
                ),
              ),
            if (preview.testMode)
              Container(
                key: const Key("chg-test-banner"),
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(8),
                color: const Color(0xFFFEF9C3),
                child: Text(
                  preview.deliveredTo.isEmpty
                      ? bi(s, "MODE TEST : le courriel sera envoyé seulement à l'adresse de test, pas aux destinataires ci-dessus.", "TEST MODE: the e-mail goes only to the test address, not to the recipients above.")
                      : bi(s, "MODE TEST : le courriel sera envoyé seulement à ", "TEST MODE: the e-mail will only be sent to ") + preview.deliveredTo.join(", "),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(key: const Key("chg-confirm-back"), onPressed: () => Navigator.of(context).pop(false), child: Text(bi(s, "Retour", "Back"))),
        FilledButton(key: const Key("chg-confirm"), onPressed: () => Navigator.of(context).pop(true), child: Text(bi(s, "Confirmer et aviser", "Confirm and notify"))),
      ],
    );
  }
}

Future<void> showOrderHistory(BuildContext context, String orderNum) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => OrderHistorySheet(orderNum: orderNum),
  );
}

/// Change history: who, when, field, old -> new.
class OrderHistorySheet extends ConsumerWidget {
  const OrderHistorySheet({super.key, required this.orderNum});
  final String orderNum;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = StringsScope.of(context);
    final async = ref.watch(orderChangesProvider(orderNum));
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(bi(s, "Historique des modifications — ", "Change history — ") + orderNum, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 8),
              Flexible(
                child: async.when(
                  loading: () => const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
                  error: (e, _) => Text(_errorText(s, e), key: const Key("history-error")),
                  data: (groups) {
                    if (groups.isEmpty) return Text(bi(s, "Aucune modification.", "No changes."), key: const Key("history-empty"));
                    return ListView(
                      shrinkWrap: true,
                      children: <Widget>[for (final g in groups) _GroupTile(group: g, french: s.isFrench)],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({required this.group, required this.french});
  final ChangeGroup group;
  final bool french;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key("history-" + group.changeId),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: const Color(0x22000000)), borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(group.changedBy + " · " + shortStamp(group.changedAt), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          for (final f in group.fields)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(f.label(french: french) + " : " + (f.oldValue.isEmpty ? "—" : f.oldValue) + " → " + (f.newValue.isEmpty ? "—" : f.newValue), style: const TextStyle(fontSize: 13)),
            ),
          if (group.reason.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 3), child: Text(group.reason, style: const TextStyle(fontSize: 12, color: Colors.black54))),
        ],
      ),
    );
  }
}
