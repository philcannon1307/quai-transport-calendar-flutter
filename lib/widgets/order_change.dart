import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "package:flutter/services.dart";
import "../api/order_change_service.dart";
import "../api/sales_order_service.dart";
import "../i18n/i18n.dart";
import "../logic/order_change.dart";
import "../models/order.dart";
import "../state/order_change_providers.dart";
import "../state/prep_providers.dart";
import "../state/providers.dart";
import "../theme/quai_tokens.dart";
import "bilingual.dart";

/// "Modifié / Changed" chip. [changed] true = show it (used where the answer is already known).
class ChangedChip extends StatelessWidget {
  const ChangedChip({super.key, this.count});
  final int? count;

  @override
  Widget build(BuildContext context) {
    final s = StringsScope.of(context);
    final c = context.q;
    final n = (count ?? 0) > 1 ? " ×" + count.toString() : "";
    // Ember "tentative" tokens (mustard on light mustard), like the Provisoire status chip.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: c.tentativeBg,
          borderRadius: BorderRadius.circular(QuaiRadius.xs),
          border: Border.all(color: c.tentative.withValues(alpha: 0.5))),
      child: Text(bi(s, "Modifié", "Changed") + n,
          style: quaiSans(c.tentative,
              size: 10, height: 12, weight: FontWeight.w700)),
    );
  }
}

/// Badge for calendar cards: shown only when the server says this order has saved changes.
class OrderChangedBadge extends ConsumerWidget {
  const OrderChangedBadge({super.key, required this.orderNum});
  final String orderNum;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref
        .watch(changedOrdersProvider)
        .valueOrNull?[orderNum.trim().toUpperCase()];
    if (info == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: KeyedSubtree(
          key: Key("changed-badge-" + orderNum),
          child: ChangedChip(count: info.count)),
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
    return KeyedSubtree(
        key: const Key("ticket-changed-badge"),
        child: ChangedChip(count: groups.length));
  }
}

String _errorText(Strings s, Object e) {
  switch (changeErrorKey(e)) {
    case "not_configured":
      return bi(s, "Le serveur n'est pas configuré.",
          "The server is not configured.");
    case "session":
      return bi(s, "Session expirée — reconnectez-vous.",
          "Session expired — sign in again.");
    case "forbidden":
      return bi(
          s,
          "Cette commande n'est pas la vôtre : vous ne pouvez pas la modifier.",
          "This is not your order: you cannot change it.");
    case "too_many":
      return bi(s, "Trop de modifications. Réessayez dans quelques minutes.",
          "Too many changes. Try again in a few minutes.");
    case "invalid":
      return bi(s, "Modification refusée — vérifiez les champs.",
          "Change refused — check the fields.");
    case "network":
      return bi(s, "Réseau indisponible.", "Network unavailable.");
    default:
      return bi(s, "Une erreur est survenue. Réessayez.",
          "Something went wrong. Try again.");
  }
}

Future<bool?> showOrderChangeScreen(BuildContext context, Order order) {
  return Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => OrderChangeScreen(order: order)),
  );
}

/// Line-by-line change: read-only order identity, then the article lines that were modified (picked from the order's own
/// lines when available, typed otherwise) and one optional general note -> "who will be notified" confirmation -> save.
class OrderChangeScreen extends ConsumerStatefulWidget {
  const OrderChangeScreen({super.key, required this.order});
  final Order order;

  @override
  ConsumerState<OrderChangeScreen> createState() => _OrderChangeScreenState();
}

class _LineCtl {
  _LineCtl({String item = "", String before = "", this.fromOrder = false})
      : item = TextEditingController(text: item),
        before = TextEditingController(text: before);
  final TextEditingController item;
  final TextEditingController before;
  final TextEditingController after = TextEditingController();
  final TextEditingController note = TextEditingController();

  /// Picked from the order: the article and "before" are fixed, only "after" (and a note) are typed.
  final bool fromOrder;

  ChangeLine toLine() => ChangeLine(
      item: item.text, before: before.text, after: after.text, note: note.text);
  void dispose() {
    item.dispose();
    before.dispose();
    after.dispose();
    note.dispose();
  }
}

class _OrderChangeScreenState extends ConsumerState<OrderChangeScreen> {
  final TextEditingController _note = TextEditingController();
  final List<_LineCtl> _lines = <_LineCtl>[];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  List<SalesOrderItem> _orderItems() {
    final o = widget.order;
    if (o.isTransfer || (o.soId ?? 0) <= 0) return const <SalesOrderItem>[];
    return ref.watch(salesOrderDetailsProvider(o.soId!)).valueOrNull?.items ??
        const <SalesOrderItem>[];
  }

  Future<void> _pick(List<SalesOrderItem> items) async {
    final taken = _lines.map((l) => l.item.text.trim().toLowerCase()).toSet();
    final i = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: context.q.surface,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(QuaiRadius.sheet))),
      builder: (_) => _PickSheet(items: items, taken: taken),
    );
    if (i == null || !mounted) return;
    final it = items[i];
    final q = it.quantity;
    setState(() {
      _error = null;
      _lines.add(_LineCtl(
          item: it.name,
          before: q == null ? "" : q.round().toString(),
          fromOrder: true));
    });
  }

  String? _issueText(Strings s, ({int index, String key}) issue) {
    final n = (issue.index + 1).toString();
    switch (issue.key) {
      case "item":
        return bi(s, "Ligne $n : indiquez l'article (70 caractères max.).",
            "Line $n: enter the item (70 characters max).");
      case "before":
        return bi(s, "Ligne $n : la quantité avant doit être un nombre entier.",
            "Line $n: the quantity before must be a whole number.");
      case "after":
        return bi(
            s,
            "Ligne $n : indiquez la nouvelle quantité (nombre entier, 0 pour retirer).",
            "Line $n: enter the new quantity (whole number, 0 to remove).");
      case "same":
        return bi(s, "Ligne $n : la quantité n'a pas changé.",
            "Line $n: the quantity did not change.");
      default:
        return bi(s, "Ligne $n : cet article est déjà dans la liste.",
            "Line $n: this item is already in the list.");
    }
  }

  Future<void> _continue() async {
    final s = StringsScope.of(context);
    final lines = _lines.map((l) => l.toLine()).toList();
    final note = _note.text.trim();
    if (lines.isEmpty && note.isEmpty) {
      setState(() => _error = bi(
          s,
          "Ajoutez au moins une ligne modifiée ou un mémo.",
          "Add at least one modified line or a note."));
      return;
    }
    final issue = firstLineIssue(lines);
    if (issue != null) {
      setState(() => _error = _issueText(s, issue));
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
      builder: (_) => ConfirmChangeDialog(
          order: widget.order, lines: lines, note: note, preview: preview),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await service.submitLines(widget.order, lines, note: note);
      ref.invalidate(orderChangesProvider(widget.order.soNum));
      ref.invalidate(changedOrdersProvider);
      if (!mounted) return;
      final msg = res.duplicate
          ? (res.testMode
              ? bi(s, "Déjà enregistré — aucun nouvel avis envoyé (mode TEST).",
                  "Already saved — no new notice sent (TEST mode).")
              : bi(s, "Déjà enregistré — aucun nouvel avis envoyé.",
                  "Already saved — no new notice sent."))
          : res.emailFailed
              ? bi(
                  s,
                  "Modification enregistrée, mais l'avis par courriel n'a pas pu être envoyé.",
                  "Change saved, but the e-mail notice could not be sent.")
              : res.testMode
                  ? bi(
                      s,
                      "Modification enregistrée. Avis envoyé en mode TEST (adresse de test seulement).",
                      "Change saved. Notice sent in TEST mode (test address only).")
                  : bi(s, "Modification enregistrée et avis envoyé.",
                      "Change saved and notice sent.");
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

  Widget _identity(Strings s, QuaiColors c) {
    final o = widget.order;
    final contact = o.isTransfer
        ? null
        : ref.watch(orderContactProvider(o.soNum)).valueOrNull;
    final rows = <MapEntry<String, String>>[
      MapEntry<String, String>(
          bi(s, "Client", "Customer"), (o.customer ?? "").trim()),
      MapEntry<String, String>(
          bi(s, "Adresse", "Address"),
          (contact?.address ?? "").trim().isNotEmpty
              ? contact!.address!.trim()
              : (o.city ?? "").trim()),
      MapEntry<String, String>(
          bi(s, "Date", "Date"), (o.shipDate ?? o.date).trim()),
      MapEntry<String, String>(
          bi(s, "Camion", "Truck"), (o.truckName ?? "").trim()),
      MapEntry<String, String>(
          bi(s, "Transporteur", "Carrier"), (o.carrierName ?? "").trim()),
    ].where((e) => e.value.isNotEmpty).toList();
    return Container(
      key: const Key("chg-identity"),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(QuaiRadius.md),
          border: Border.all(color: c.line)),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(o.soNum,
                key: const Key("chg-identity-num"),
                style: quaiMono(c.ink, size: 16)),
            for (final e in rows)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text.rich(TextSpan(children: <InlineSpan>[
                  TextSpan(
                      text: e.key + " : ",
                      style: quaiSans(c.sub,
                          size: 13, height: 18, weight: FontWeight.w600)),
                  TextSpan(
                      text: e.value,
                      style: quaiSans(c.ink, size: 14, height: 19)),
                ])),
              ),
          ]),
    );
  }

  InputDecoration _dec(String label) => InputDecoration(
      labelText: label,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14));

  Widget _lineCard(int i, Strings s, QuaiColors c) {
    final l = _lines[i];
    return Container(
      key: Key("chg-line-$i"),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 14),
      decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(QuaiRadius.md),
          border: Border.all(color: c.line)),
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[l.before, l.after]),
        builder: (context, _) {
          final action =
              ChangeLine(before: l.before.text, after: l.after.text).action;
          final showAction = RegExp(r"^\d{1,6}$").hasMatch(l.after.text.trim());
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(children: <Widget>[
                  Expanded(
                    child: l.fromOrder
                        ? Text(l.item.text,
                            key: Key("chg-line-$i-item"),
                            style: quaiSans(c.ink,
                                size: 15, height: 20, weight: FontWeight.w700))
                        : Padding(
                            padding: const EdgeInsets.only(top: 4, right: 8),
                            child: TextField(
                                key: Key("chg-line-$i-item"),
                                controller: l.item,
                                enabled: !_busy,
                                textInputAction: TextInputAction.next,
                                decoration:
                                    _dec(bi(s, "Article / SKU", "Item / SKU"))),
                          ),
                  ),
                  IconButton(
                    key: Key("chg-line-$i-remove"),
                    tooltip: bi(s, "Retirer cette ligne", "Remove this line"),
                    constraints: const BoxConstraints(
                        minWidth: QuaiSpace.tapMin,
                        minHeight: QuaiSpace.tapMin),
                    onPressed: _busy
                        ? null
                        : () => setState(() => _lines.removeAt(i).dispose()),
                    icon: Icon(Icons.close, size: 22, color: c.sub),
                  ),
                ]),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(children: <Widget>[
                    Expanded(
                      child: l.fromOrder
                          ? Container(
                              key: Key("chg-line-$i-before"),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 15),
                              decoration: BoxDecoration(
                                  color: c.field,
                                  borderRadius:
                                      BorderRadius.circular(QuaiRadius.sm)),
                              child: Text(
                                  bi(s, "Avant : ", "Before: ") +
                                      (l.before.text.isEmpty
                                          ? "—"
                                          : l.before.text),
                                  style: quaiSans(c.sub,
                                      size: 15,
                                      height: 20,
                                      weight: FontWeight.w600)),
                            )
                          : TextField(
                              key: Key("chg-line-$i-before"),
                              controller: l.before,
                              enabled: !_busy,
                              keyboardType: TextInputType.number,
                              inputFormatters: <TextInputFormatter>[
                                FilteringTextInputFormatter.digitsOnly
                              ],
                              decoration: _dec(bi(s, "Avant", "Before"))),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                          key: Key("chg-line-$i-after"),
                          controller: l.after,
                          enabled: !_busy,
                          autofocus: l.fromOrder,
                          keyboardType: TextInputType.number,
                          inputFormatters: <TextInputFormatter>[
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          decoration: _dec(bi(s, "Après", "After"))),
                    ),
                  ]),
                ),
                SizedBox(
                  height: 28,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: showAction
                        ? Text(lineActionLabel(action, french: s.isFrench),
                            key: Key("chg-line-$i-action"),
                            style: quaiSans(c.primaryInk,
                                size: 13, height: 18, weight: FontWeight.w700))
                        : null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 8),
                  child: TextField(
                      key: Key("chg-line-$i-note"),
                      controller: l.note,
                      enabled: !_busy,
                      decoration:
                          _dec(bi(s, "Note (facultatif)", "Note (optional)"))),
                ),
              ]);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = StringsScope.of(context);
    final c = context.q;
    final items = _orderItems();
    final canAdd = !_busy && _lines.length < kMaxChangeLines;
    const bigBtn = Size(0, QuaiSpace.tapMin);
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        title: Text(
            bi(s, "Modifier la commande ", "Change order ") +
                widget.order.soNum,
            key: const Key("chg-title"),
            style: quaiSans(Colors.white,
                size: 17, height: 22, weight: FontWeight.w700)),
        actions: <Widget>[
          TextButton(
              style: TextButton.styleFrom(
                  foregroundColor: Colors.white, minimumSize: bigBtn),
              key: const Key("chg-cancel"),
              onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
              child: Text(bi(s, "Annuler", "Cancel"))),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              bi(
                  s,
                  "Ajoutez seulement les articles modifiés, ligne par ligne. Les divisions concernées sont avisées par courriel. NetSuite n'est pas modifié.",
                  "Add only the modified items, line by line. The divisions concerned are notified by e-mail. NetSuite is not changed."),
              style: quaiSans(c.sub, size: 12, height: 17),
            ),
            const SizedBox(height: 12),
            _identity(s, c),
            const SizedBox(height: 18),
            Text(bi(s, "Lignes modifiées", "Modified lines"),
                style: quaiSans(c.ink,
                    size: 15, height: 20, weight: FontWeight.w700)),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  bi(
                      s,
                      "Les lignes de la commande ne sont pas disponibles ici : saisissez l'article, la quantité avant et la quantité après.",
                      "The order's lines are not available here: type the item, the quantity before and the quantity after."),
                  key: const Key("chg-no-items-hint"),
                  style: quaiSans(c.sub, size: 12, height: 17),
                ),
              ),
            for (var i = 0; i < _lines.length; i++) _lineCard(i, s, c),
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 8, children: <Widget>[
              if (items.isNotEmpty)
                OutlinedButton.icon(
                  key: const Key("chg-pick-line"),
                  style: OutlinedButton.styleFrom(minimumSize: bigBtn),
                  onPressed: canAdd ? () => _pick(items) : null,
                  icon: const Icon(Icons.list_alt, size: 20),
                  label: Text(bi(s, "Choisir une ligne de la commande",
                      "Pick a line from the order")),
                ),
              OutlinedButton.icon(
                key: const Key("chg-add-line"),
                style: OutlinedButton.styleFrom(minimumSize: bigBtn),
                onPressed: canAdd
                    ? () => setState(() {
                          _error = null;
                          _lines.add(_LineCtl());
                        })
                    : null,
                icon: const Icon(Icons.add, size: 20),
                label: Text(bi(s, "Ajouter une ligne", "Add a line")),
              ),
            ]),
            const SizedBox(height: 18),
            TextField(
              key: const Key("chg-note"),
              controller: _note,
              enabled: !_busy,
              maxLines: 3,
              minLines: 2,
              decoration: _dec(bi(
                  s, "Mémo / raison (facultatif)", "Note / reason (optional)")),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!,
                    key: const Key("chg-error"),
                    style: quaiSans(c.cancelled,
                        size: 13, height: 18, weight: FontWeight.w600)),
              ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key("chg-continue"),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(QuaiSpace.tapMin)),
              onPressed: _busy ? null : _continue,
              child: _busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: c.onPrimary))
                  : Text(bi(s, "Continuer", "Continue")),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet: the order's own lines (name, SKU, quantity). Returns the tapped index.
class _PickSheet extends StatelessWidget {
  const _PickSheet({required this.items, required this.taken});
  final List<SalesOrderItem> items;
  final Set<String> taken;

  @override
  Widget build(BuildContext context) {
    final s = StringsScope.of(context);
    final c = context.q;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(bi(s, "Lignes de la commande", "Order lines"),
                    style: quaiSans(c.ink,
                        size: 16, height: 22, weight: FontWeight.w700)),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final it = items[i];
                    final used = taken.contains(it.name.trim().toLowerCase());
                    final q = it.quantity;
                    return ListTile(
                      key: Key("chg-pick-$i"),
                      minVerticalPadding: 10,
                      enabled: !used,
                      title: Text(it.name,
                          style: quaiSans(used ? c.faint : c.ink,
                              size: 15, height: 20, weight: FontWeight.w600)),
                      subtitle: it.sku.isEmpty
                          ? null
                          : Text(it.sku, style: quaiMono(c.sub, size: 12)),
                      trailing: Text(
                        (q == null ? "—" : q.round().toString()) +
                            (it.unit.isEmpty ? "" : " " + it.unit),
                        style: quaiSans(used ? c.faint : c.ink,
                            size: 15, height: 20, weight: FontWeight.w700),
                      ),
                      onTap: used ? null : () => Navigator.of(context).pop(i),
                    );
                  },
                ),
              ),
            ]),
      ),
    );
  }
}

/// Last step before saving: the modified lines and exactly who will be e-mailed.
class ConfirmChangeDialog extends StatelessWidget {
  const ConfirmChangeDialog(
      {super.key,
      required this.order,
      required this.lines,
      required this.note,
      required this.preview});
  final Order order;
  final List<ChangeLine> lines;
  final String note;
  final PreviewResult preview;

  @override
  Widget build(BuildContext context) {
    final s = StringsScope.of(context);
    final fr = s.isFrench;
    final c = context.q;
    final body = quaiSans(c.ink, size: 13, height: 18);
    final head = quaiSans(c.ink, size: 14, height: 20, weight: FontWeight.w700);
    const btn = Size(0, QuaiSpace.tapMin);
    return AlertDialog(
      key: const Key("chg-confirm-dialog"),
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(QuaiRadius.lg)),
      title: Text(bi(s, "Confirmer la modification", "Confirm the change"),
          style:
              quaiSans(c.ink, size: 18, height: 24, weight: FontWeight.w700)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(order.soNum, style: quaiMono(c.sub, size: 13)),
            const SizedBox(height: 6),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  l.item.trim() +
                      " : " +
                      (l.before.trim().isEmpty ? "0" : l.before.trim()) +
                      " → " +
                      l.after.trim() +
                      " (" +
                      lineActionLabel(l.action, french: fr) +
                      ")" +
                      (l.note.trim().isEmpty ? "" : " — " + l.note.trim()),
                  style: body,
                ),
              ),
            if (note.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(bi(s, "Mémo : ", "Note: ") + note,
                      key: const Key("chg-confirm-note"), style: body)),
            Divider(color: c.line),
            Text(
                bi(s, "Seront avisés par courriel :",
                    "Will be notified by e-mail:"),
                style: head),
            for (final r in preview.recipients)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  (r.email.isNotEmpty
                          ? r.email + " — "
                          : (r.division ?? "").isNotEmpty
                              ? r.division! + " — "
                              : "") +
                      r.roles.map((x) => roleLabel(x, french: fr)).join(", "),
                  key: Key("chg-recipient-" +
                      (r.email.isNotEmpty ? r.email : r.roles.join("+"))),
                  style: body,
                ),
              ),
            if (preview.unresolved.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  bi(s, "Division introuvable pour : ",
                          "Division not found for: ") +
                      preview.unresolved.join(", "),
                  key: const Key("chg-unresolved"),
                  style: quaiSans(c.cancelled,
                      size: 12, height: 16, weight: FontWeight.w600),
                ),
              ),
            if (preview.testMode)
              Container(
                key: const Key("chg-test-banner"),
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: c.tentativeBg,
                    borderRadius: BorderRadius.circular(QuaiRadius.sm)),
                child: Text(
                  preview.deliveredTo.isEmpty
                      ? bi(
                          s,
                          "MODE TEST : le courriel sera envoyé seulement à l'adresse de test, pas aux destinataires ci-dessus.",
                          "TEST MODE: the e-mail goes only to the test address, not to the recipients above.")
                      : bi(s, "MODE TEST : le courriel sera envoyé seulement à ",
                              "TEST MODE: the e-mail will only be sent to ") +
                          preview.deliveredTo.join(", "),
                  style: quaiSans(c.tentative,
                      size: 12, height: 17, weight: FontWeight.w700),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
            style:
                TextButton.styleFrom(minimumSize: btn, foregroundColor: c.sub),
            key: const Key("chg-confirm-back"),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(bi(s, "Retour", "Back"))),
        FilledButton(
            style: FilledButton.styleFrom(minimumSize: btn),
            key: const Key("chg-confirm"),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(bi(s, "Confirmer et aviser", "Confirm and notify"))),
      ],
    );
  }
}

Future<void> showOrderHistory(BuildContext context, String orderNum) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: context.q.surface,
    shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(QuaiRadius.sheet))),
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
    final c = context.q;
    final async = ref.watch(orderChangesProvider(orderNum));
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                  bi(s, "Historique des modifications — ",
                          "Change history — ") +
                      orderNum,
                  style: quaiSans(c.ink,
                      size: 16, height: 22, weight: FontWeight.w700)),
              const SizedBox(height: 8),
              Flexible(
                child: async.when(
                  loading: () => Center(
                      child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: CircularProgressIndicator(color: c.primary))),
                  error: (e, _) => Text(_errorText(s, e),
                      key: const Key("history-error"),
                      style: quaiSans(c.cancelled, size: 13, height: 18)),
                  data: (groups) {
                    if (groups.isEmpty)
                      return Text(bi(s, "Aucune modification.", "No changes."),
                          key: const Key("history-empty"),
                          style: quaiSans(c.sub, size: 14, height: 20));
                    return ListView(
                      shrinkWrap: true,
                      children: <Widget>[
                        for (final g in groups)
                          _GroupTile(group: g, french: s.isFrench)
                      ],
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
    final c = context.q;
    return Container(
      key: Key("history-" + group.changeId),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: c.field,
          border: Border.all(color: c.line),
          borderRadius: BorderRadius.circular(QuaiRadius.sm)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(group.changedBy + " · " + shortStamp(group.changedAt),
              style: quaiSans(c.ink,
                  size: 13, height: 18, weight: FontWeight.w700)),
          for (final f in group.fields)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(f.summary(french: french),
                  key: Key("history-line-" + f.field),
                  style: quaiSans(c.ink, size: 13, height: 18)),
            ),
          if (group.reason.isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(group.reason,
                    style: quaiSans(c.sub, size: 12, height: 17))),
        ],
      ),
    );
  }
}
