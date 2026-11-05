import "dart:async";
import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../api/sales_order_service.dart";
import "../api/ticket_service.dart";
import "../i18n/i18n.dart";
import "../logic/ticket_progress.dart";
import "../models/order.dart";
import "../pdf/pdf_ports.dart";
import "../state/providers.dart";
import "../theme.dart";
import "../widgets/order_change.dart";
import "../widgets/provisional_ticket_view.dart";

Future<void> showTicketSheet(BuildContext context, String orderNum,
    {Order? order}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => TicketSheet(orderNum: orderNum, order: order)),
  );
}

/// Picking-ticket viewer: honest progress while NetSuite builds the PDF,
/// print / download, and a big red Close that is always reachable.
class TicketSheet extends ConsumerStatefulWidget {
  const TicketSheet({super.key, required this.orderNum});
  final String orderNum;

  @override
  ConsumerState<TicketSheet> createState() => _TicketSheetState();
}

class _TicketSheetState extends ConsumerState<TicketSheet> {
  static const int _tickMs = 200;

  Timer? _timer;
  int _ticks = 0;
  double _progress = kStartProgress;
  TicketPhase _phase = TicketPhase.server;
  Uint8List? _bytes;
  String? _error;
  SalesOrderDetails? _provisional;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onProgress(TicketPhase phase, double? fraction) {
    if (!mounted || phase != TicketPhase.download) return;
    _timer?.cancel();
    setState(() {
      _phase = TicketPhase.download;
      _progress = downloadProgress(_progress, fraction);
    });
  }

  Future<void> _start() async {
    _timer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _bytes = null;
      _provisional = null;
      _ticks = 0;
      _progress = kStartProgress;
      _phase = TicketPhase.server;
    });
    // Ticks (not wall-clock) drive the easing, so it is deterministic in tests.
    _timer = Timer.periodic(const Duration(milliseconds: _tickMs), (_) {
      if (!mounted) return;
      _ticks++;
      setState(
          () => _progress = nextServerProgress(_progress, _ticks * _tickMs));
    });
    try {
      final bytes = await ref
          .read(ticketServiceProvider)
          .getTicket(widget.orderNum, onProgress: _onProgress);
      _timer?.cancel();
      if (!mounted) return;
      setState(() {
        _phase = TicketPhase.render;
        _bytes = Uint8List.fromList(bytes);
        _progress = kDoneProgress;
        _loading = false;
      });
    } on TicketException catch (e) {
      _timer?.cancel();
      final provisional = e.status == 404 ? await _provisionalFor(widget.orderNum) : null;
      if (!mounted) return;
      if (provisional != null) {
        setState(() {
          _provisional = provisional;
          _loading = false;
        });
        return;
      }
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      _timer?.cancel();
      if (!mounted) return;
      final message = StringsScope.of(context).t("tbl.ticketError");
      setState(() {
        _error = message;
        _loading = false;
      });
    }
  }

  /// No truck yet (the job service has no ticket): Logistique / SuperUser get the provisional list.
  Future<SalesOrderDetails?> _provisionalFor(String soNum) async {
    final service = ref.read(salesOrderServiceProvider);
    if (service == null) return null;
    final orders = await ref.read(ordersProvider.future).catchError((_) => <Order>[]);
    final id = orders.where((o) => o.soNum == soNum && (o.soId ?? 0) > 0).map((o) => o.soId!).firstOrNull;
    return id == null ? null : service.fetch(id);
  }

  Future<void> _print() async {
    final bytes = _bytes;
    if (bytes == null) return;
    try {
      await ref
          .read(ticketFileActionsProvider)
          .printPdf(bytes, widget.orderNum);
    } catch (_) {
      // the browser blocked or cancelled printing: nothing to recover
    }
  }

  Future<void> _download() async {
    final bytes = _bytes;
    if (bytes == null) return;
    try {
      await ref
          .read(ticketFileActionsProvider)
          .download(bytes, widget.orderNum);
    } catch (_) {
      // the browser blocked the download: nothing to recover
    }
  }

  String get _phaseText {
    switch (_phase) {
      case TicketPhase.server:
        return "NetSuite prépare le document… / NetSuite is preparing the document…";
      case TicketPhase.download:
        return "Téléchargement… / Downloading…";
      case TicketPhase.render:
        return "Affichage… / Displaying…";
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _bytes != null && !_loading;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(
          widget.orderNum,
          key: const Key("ticket-title"),
          style: const TextStyle(
              fontFamily: "monospace",
              fontWeight: FontWeight.w600,
              fontSize: 15),
        ),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              key: const Key("ticket-close"),
              style: FilledButton.styleFrom(
                backgroundColor: CardPalette.past,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 44),
                textStyle: const TextStyle(fontWeight: FontWeight.w700),
              ),
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close, size: 20),
              label: const Text("Fermer / Close"),
            ),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                OutlinedButton.icon(
                  key: const Key("ticket-print"),
                  onPressed: ready ? _print : null,
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text("Imprimer / Print"),
                ),
                OutlinedButton.icon(
                  key: const Key("ticket-download"),
                  onPressed: ready ? _download : null,
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text("Télécharger / Download"),
                ),
                if (widget.order != null)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        textStyle: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    key: const Key("ticket-change"),
                    onPressed: () => showOrderChangeScreen(context, widget.order!),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text("Modifier la commande / Change order"),
                  ),
                OutlinedButton.icon(
                  key: const Key("ticket-history"),
                  onPressed: () => showOrderHistory(context, widget.orderNum),
                  icon: const Icon(Icons.history, size: 18),
                  label: const Text("Historique / History"),
                ),
                TicketChangedBadge(orderNum: widget.orderNum),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: <Widget>[
                if (_bytes != null)
                  Positioned.fill(
                      child: ref.watch(ticketPdfBuilderProvider)(
                          context, _bytes!, widget.orderNum)),
                if (_error != null)
                  Positioned.fill(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const Icon(Icons.error_outline,
                                color: CardPalette.past),
                            const SizedBox(height: 8),
                            Text(_error!,
                                key: const Key("ticket-error"),
                                textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            OutlinedButton(
                              key: const Key("ticket-retry"),
                              onPressed: _start,
                              child: const Text("Réessayer / Retry"),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_loading)
                  Positioned.fill(
                    child: ColoredBox(
                      color: const Color(0xD9FFFFFF),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 320),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(_phaseText,
                                    key: const Key("ticket-phase"),
                                    textAlign: TextAlign.center),
                                const SizedBox(height: 12),
                                LinearProgressIndicator(
                                    key: const Key("ticket-progress"),
                                    value: _progress / 100),
                                const SizedBox(height: 6),
                                Text("${_progress.round()}%",
                                    style: const TextStyle(
                                        fontSize: 12, color: Colors.black54)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
