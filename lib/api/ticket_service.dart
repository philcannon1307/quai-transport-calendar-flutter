import "dart:async";

import "../data/carriers.dart";
import "../logic/ticket_cache.dart";
import "../logic/ticket_progress.dart";
import "../models/order.dart";

/// Raw HTTP outcome of one picking-ticket request.
class TicketHttpResult {
  const TicketHttpResult(this.status, [this.bytes]);
  final int status;
  final List<int>? bytes;
  bool get ok => status >= 200 && status < 300;
}

typedef TicketFetch = Future<TicketHttpResult> Function(
  String? token,
  String ticketNum, {
  void Function(double? fraction)? onDownload,
});

/// Where the service finds tokens. Backed by the session; faked in tests.
abstract class TicketTokens {
  /// The signed-in session's own token.
  String? primaryToken();

  /// Token of the Gooseneck truck that OWNS this transfer order, if known.
  String? transferToken(String toNum);

  /// Calendar name of the signed-in carrier.
  String? carrierName();

  /// Tokens of the individual SADM trucks (Logistique only; Gooseneck excluded).
  List<String> sadmTruckTokens();
}

class TicketException implements Exception {
  const TicketException(this.message, this.status, {this.unauthorized = false});
  final String message;
  final int status;
  final bool unauthorized;
  @override
  String toString() => message;
}

/// Picking-ticket fetching with the reference app's rules:
///  - only the OWNING truck's token works; transfers use the per-owner token map
///  - a 404 is retried ONCE (NetSuite sometimes needs a second ask)
///  - SADM - Logistique: its own token only sees one truck's orders, so on a 404
///    every SADM truck's token is tried in parallel and the first success wins
///  - 401/403 means the session is stale
///  - 10-minute in-memory cache
class TicketService {
  TicketService({
    required this.fetch,
    required this.tokens,
    TicketCache? cache,
    this.retryDelay = const Duration(seconds: 1),
  }) : cache = cache ?? TicketCache();

  final TicketFetch fetch;
  final TicketTokens tokens;
  final TicketCache cache;
  final Duration retryDelay;

  Future<List<int>> getTicket(
    String orderNum, {
    void Function(TicketPhase phase, double? fraction)? onProgress,
  }) async {
    final cached = cache.get(orderNum);
    if (cached != null) {
      onProgress?.call(TicketPhase.download, 1);
      return cached;
    }
    onProgress?.call(TicketPhase.server, null);

    void onDownload(double? f) => onProgress?.call(TicketPhase.download, f);

    final isTransfer = isTransferNum(orderNum);
    var token = tokens.primaryToken();
    if (isTransfer) {
      final owner = tokens.transferToken(orderNum);
      if (owner != null) token = owner;
    }

    var res = await fetch(token, orderNum, onDownload: onDownload);

    if (res.status == 404 && !isTransfer && tokens.carrierName() == kLogistique) {
      final alt = await _fromSadmTrucks(orderNum);
      if (alt != null) res = alt;
    }
    if (res.status == 404) {
      await Future<void>.delayed(retryDelay);
      res = await fetch(token, orderNum, onDownload: onDownload);
    }

    if (res.status == 401 || res.status == 403) {
      throw TicketException("Session expirée.", res.status, unauthorized: true);
    }
    if (res.status == 404) {
      throw const TicketException("Bon de commande temporairement indisponible — veuillez réessayer.", 404);
    }
    if (res.status == 0) {
      throw const TicketException("Réseau indisponible / Network unavailable.", 0);
    }
    final bytes = res.bytes;
    if (!res.ok || bytes == null) {
      throw TicketException("Erreur ${res.status}", res.status);
    }
    cache.put(orderNum, bytes);
    return bytes;
  }

  /// Asks every SADM truck in parallel; first success wins, null if none.
  Future<TicketHttpResult?> _fromSadmTrucks(String orderNum) {
    final truckTokens = tokens.sadmTruckTokens();
    if (truckTokens.isEmpty) return Future<TicketHttpResult?>.value(null);
    final done = Completer<TicketHttpResult?>();
    var pending = truckTokens.length;
    for (final t in truckTokens) {
      () async {
        try {
          final r = await fetch(t, orderNum);
          if (r.ok && !done.isCompleted) {
            done.complete(r);
            return;
          }
        } catch (_) {
          // try the next truck
        }
        pending--;
        if (pending == 0 && !done.isCompleted) done.complete(null);
      }();
    }
    return done.future;
  }
}
