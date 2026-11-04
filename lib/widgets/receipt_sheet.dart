import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../api/receipts_service.dart";
import "../i18n/i18n.dart";
import "../logic/receipts_policy.dart";
import "../platform/photo_picker.dart";
import "../state/providers.dart";
import "bilingual.dart";

/// REÇUS (everyone allowed) or BOL (SADM - Logistique). Returns true when sent.
Future<bool?> showReceiptSheet(BuildContext context, {required bool bol}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ReceiptSheet(bol: bol),
    ),
  );
}

class ReceiptSheet extends ConsumerStatefulWidget {
  const ReceiptSheet({super.key, required this.bol});
  final bool bol;

  @override
  ConsumerState<ReceiptSheet> createState() => _ReceiptSheetState();
}

class _ReceiptSheetState extends ConsumerState<ReceiptSheet> {
  final TextEditingController _driver = TextEditingController();
  final TextEditingController _note = TextEditingController();
  PickedPhoto? _photo;
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _driver.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final p = await ref.read(photoPickerProvider).takePhoto();
    if (p != null && mounted) setState(() => _photo = p);
  }

  String _failureText(Strings s, ReceiptFailure f) {
    switch (f) {
      case ReceiptFailure.noPhoto:
        return s.t("receipts.errorPhoto");
      case ReceiptFailure.noDriver:
        return s.t("receipts.errorDriver");
      case ReceiptFailure.upload:
        return s.t("receipts.errorUpload");
      case ReceiptFailure.email:
        return s.t("receipts.errorEmail");
      case ReceiptFailure.unreadablePhoto:
        return bi(s, "Cette photo est illisible. Reprenez-la.",
            "This photo cannot be read. Take it again.");
      case ReceiptFailure.notConfigured:
        return bi(s, "Le serveur d'envoi n'est pas configuré.",
            "The upload server is not configured.");
    }
  }

  Future<void> _send(Strings s) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final carrier = ref.read(currentCarrierProvider) ?? "";
    final res = await ref.read(receiptsServiceProvider).submit(
          photo: _photo?.bytes,
          driver: _driver.text,
          carrierName: carrier,
          note: _note.text,
          bol: widget.bol,
        );
    if (!mounted) return;
    if (res.isOk) {
      if (res.suppressed) {
        setState(() {
          _busy = false;
          _info = bi(
              s,
              "Photo enregistrée, mais le destinataire s'est désabonné : aucun courriel envoyé.",
              "Photo saved, but the recipient unsubscribed: no email was sent.");
        });
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(s.t(widget.bol ? "bol.success" : "receipts.success"))));
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
    final bol = widget.bol;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(s.t(bol ? "bol.title" : "receipts.title"),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(s.t(bol ? "bol.subtitle" : "receipts.subtitle"),
                style: const TextStyle(color: Colors.black54, fontSize: 12)),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              key: const Key("receipt-pick"),
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(_photo == null
                  ? s.t(bol ? "bol.choosePhoto" : "receipts.choosePhoto")
                  : _photo!.name),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key("receipt-driver"),
              controller: _driver,
              decoration: InputDecoration(
                labelText: s.t("receipts.driver"),
                hintText: s.t("receipts.driverPlaceholder"),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key("receipt-note"),
              controller: _note,
              decoration: InputDecoration(
                labelText: s.t("receipts.note"),
                hintText: s.t(
                    bol ? "bol.notePlaceholder" : "receipts.notePlaceholder"),
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(_error!,
                  key: const Key("receipt-error"),
                  style:
                      const TextStyle(color: Color(0xFF9B1C1C), fontSize: 13)),
            ],
            if (_info != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(_info!,
                  key: const Key("receipt-info"),
                  style:
                      const TextStyle(color: Color(0xFF92400E), fontSize: 13)),
            ],
            const SizedBox(height: 14),
            FilledButton(
              key: const Key("receipt-send"),
              onPressed: _busy ? null : () => _send(s),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(_busy
                    ? s.t("receipts.sending")
                    : s.t(bol ? "bol.send" : "receipts.send")),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Which button the AppBar shows: null = none.
({bool show, bool bol}) receiptButtonFor(String? carrier,
        {required bool isSuperUser}) =>
    (
      show: canUploadReceipts(carrier, isSuperUser: isSuperUser),
      bol: isBolMode(carrier)
    );
