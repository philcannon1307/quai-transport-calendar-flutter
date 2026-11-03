import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../api/adjustment_service.dart";
import "../i18n/i18n.dart";
import "../logic/adjustment.dart";
import "../logic/ids.dart";
import "../models/order.dart";
import "../platform/photo_picker.dart";
import "../state/providers.dart";
import "bilingual.dart";

Future<bool?> showAdjustmentSheet(BuildContext context, Order order) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: AdjustmentSheet(order: order),
    ),
  );
}

class AdjustmentSheet extends ConsumerStatefulWidget {
  const AdjustmentSheet({super.key, required this.order});
  final Order order;

  @override
  ConsumerState<AdjustmentSheet> createState() => _AdjustmentSheetState();
}

class _RowCtl {
  final TextEditingController item = TextEditingController();
  final TextEditingController from = TextEditingController();
  final TextEditingController to = TextEditingController();
  final TextEditingController reason = TextEditingController();
  AdjustmentRow toRow() => AdjustmentRow(item: item.text, from: from.text, to: to.text, reason: reason.text);
  void dispose() {
    item.dispose();
    from.dispose();
    to.dispose();
    reason.dispose();
  }
}

class _AdjustmentSheetState extends ConsumerState<AdjustmentSheet> {
  // One id per form: a retry after a partial failure reuses it, so no email can go twice.
  final String _reportId = newUuid4();
  final List<_RowCtl> _rows = <_RowCtl>[_RowCtl()];
  final TextEditingController _name = TextEditingController();
  final TextEditingController _note = TextEditingController();
  PickedPhoto? _photo;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  String _failureText(Strings s, AdjustmentFailure f) {
    switch (f) {
      case AdjustmentFailure.noItems:
        return bi(s, "Ajoutez au moins un article.", "Add at least one item.");
      case AdjustmentFailure.unreadablePhoto:
        return bi(s, "Cette photo est illisible. Reprenez-la.", "This photo cannot be read. Take it again.");
      case AdjustmentFailure.notConfigured:
        return bi(s, "Le serveur d'envoi n'est pas configuré.", "The upload server is not configured.");
      case AdjustmentFailure.photoUpload:
        return bi(s, "Échec du téléversement de la photo. Réessayez.", "Photo upload failed. Please try again.");
      case AdjustmentFailure.badRecipient:
        return bi(s, "Aucun destinataire valide pour ce transporteur.", "No valid recipient for this carrier.");
      case AdjustmentFailure.email:
        return bi(s, "Le courriel n'a pas pu être envoyé. Réessayez.", "The email could not be sent. Please try again.");
    }
  }

  Future<void> _send(Strings s) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final o = widget.order;
    final res = await ref.read(adjustmentServiceProvider).submit(
          reportId: _reportId,
          orderNum: o.soNum,
          carrierName: ref.read(currentCarrierProvider) ?? o.carrierName ?? "",
          reporterName: _name.text,
          rows: _rows.map((r) => r.toRow()).toList(),
          note: _note.text,
          photo: _photo?.bytes,
          photoName: _photo?.name ?? "photo.jpg",
          transferLocations: o.isTransfer
              ? <String>[
                  if ((o.shippingLocationName ?? "").isNotEmpty) o.shippingLocationName!,
                  if ((o.saleLocationName ?? "").isNotEmpty) o.saleLocationName!,
                ]
              : const <String>[],
        );
    if (!mounted) return;
    if (res.isOk) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(res.suppressedCount > 0
            ? bi(s, "Changement enregistré; un destinataire s'est désabonné.", "Change logged; one recipient had unsubscribed.")
            : bi(s, "Changement signalé ✓", "Change reported ✓")),
      ));
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = _failureText(s, res.failure!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = StringsScope.of(context);
    final o = widget.order;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(bi(s, "Signaler un changement — ${o.soNum}", "Report a change — ${o.soNum}"),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextField(
              key: const Key("adj-name"),
              controller: _name,
              decoration: InputDecoration(labelText: s.t("receipts.driver"), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < _rows.length; i++) ...<Widget>[
              Container(
                key: Key("adj-row-$i"),
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(border: Border.all(color: const Color(0x22000000)), borderRadius: BorderRadius.circular(10)),
                child: Column(
                  children: <Widget>[
                    TextField(
                      key: Key("adj-item-$i"),
                      controller: _rows[i].item,
                      decoration: InputDecoration(labelText: bi(s, "Article", "Item"), isDense: true),
                    ),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            key: Key("adj-from-$i"),
                            controller: _rows[i].from,
                            decoration: InputDecoration(labelText: bi(s, "Prévu", "Planned"), isDense: true),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            key: Key("adj-to-$i"),
                            controller: _rows[i].to,
                            decoration: InputDecoration(labelText: bi(s, "Réel", "Actual"), isDense: true),
                          ),
                        ),
                      ],
                    ),
                    TextField(
                      key: Key("adj-reason-$i"),
                      controller: _rows[i].reason,
                      decoration: InputDecoration(labelText: bi(s, "Raison", "Reason"), isDense: true),
                    ),
                  ],
                ),
              ),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key("adj-add"),
                onPressed: _busy ? null : () => setState(() => _rows.add(_RowCtl())),
                icon: const Icon(Icons.add),
                label: Text(bi(s, "Ajouter un article", "Add an item")),
              ),
            ),
            TextField(
              key: const Key("adj-note"),
              controller: _note,
              maxLines: 2,
              decoration: InputDecoration(labelText: s.t("receipts.note"), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key("adj-photo"),
              onPressed: _busy
                  ? null
                  : () async {
                      final p = await ref.read(photoPickerProvider).takePhoto();
                      if (p != null && mounted) setState(() => _photo = p);
                    },
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(_photo == null ? s.t("receipts.choosePhoto") : _photo!.name),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(_error!, key: const Key("adj-error"), style: const TextStyle(color: Color(0xFF9B1C1C), fontSize: 13)),
            ],
            const SizedBox(height: 14),
            FilledButton(
              key: const Key("adj-send"),
              onPressed: _busy ? null : () => _send(s),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(_busy ? s.t("receipts.sending") : bi(s, "Envoyer le changement", "Send change")),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
