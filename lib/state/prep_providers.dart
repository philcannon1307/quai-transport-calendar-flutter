import "package:flutter_riverpod/flutter_riverpod.dart";

import "../api/prep_state_service.dart";
import "../api/sales_order_service.dart";
import "../logic/prep_state.dart";
import "../models/order.dart";
import "order_change_providers.dart";
import "providers.dart";

final prepServiceProvider =
    Provider<PrepStateService>((ref) => PrepStateService(transport: ref.watch(orderChangeTransportProvider)));

/// True when the signed-in session may change the prepared state (role from the exchange; the server enforces it).
bool sessionCanPrepare(WidgetRef ref) {
  ref.watch(currentCarrierProvider); // re-evaluated when somebody signs in or out
  return canPrepare(ref.read(sessionProvider).role());
}

class PrepModel {
  const PrepModel({this.entries = const <String, PrepEntry>{}, this.failed = false});
  final Map<String, PrepEntry> entries;

  /// The last refresh failed (offline, server down): the numbers shown may be stale.
  final bool failed;

  PrepEntry? of(Order o) => entries[prepKeyOf(o)];
  bool isPrepared(Order o) => entries[prepKeyOf(o)]?.prepared == true;
}

/// Holds the prepared states the app knows about. A refresh replaces the window it asked for, except the keys
/// that have a change in flight (so a poll cannot undo a tap that is still being saved).
class PrepController extends StateNotifier<PrepModel> {
  PrepController(this._service, this._me) : super(const PrepModel());
  final PrepStateService _service;
  final String _me;
  final Map<String, int> _pending = <String, int>{};
  final Map<String, Future<void>> _tail = <String, Future<void>>{};

  Future<void> refresh(String from, String to) async {
    if (!_service.configured) return;
    try {
      final fresh = await _service.fetch(from, to);
      if (!mounted) return;
      final next = Map<String, PrepEntry>.of(state.entries);
      next.removeWhere((k, _) {
        final d = k.substring(k.indexOf("|") + 1);
        return d.compareTo(from) >= 0 && d.compareTo(to) <= 0 && !_pending.containsKey(k);
      });
      fresh.forEach((k, v) {
        if (!_pending.containsKey(k)) next[k] = v;
      });
      state = PrepModel(entries: next);
    } catch (_) {
      if (mounted) state = PrepModel(entries: state.entries, failed: true);
    }
  }

  /// Optimistic: the button flips at once, the server call follows; on failure the old state comes back and the error is rethrown.
  Future<void> setPrepared(Order o, bool prepared, {required DateTime now}) {
    final key = prepKeyOf(o);
    final before = state.entries[key];
    _pending[key] = (_pending[key] ?? 0) + 1;
    _put(key, prepared ? PrepEntry(prepared: true, by: _me, at: now) : null);
    final previous = _tail[key] ?? Future<void>.value();
    final run = previous.catchError((_) {}).then((_) async {
      try {
        final saved = await _service.set(o.soNum, prepDateOf(o), prepared);
        if (_pending[key] == 1) _put(key, saved.prepared ? saved : null);
      } catch (e) {
        if (_pending[key] == 1) _put(key, before);
        rethrow;
      }
    });
    _tail[key] = run;
    return run.whenComplete(() {
      final n = (_pending[key] ?? 1) - 1;
      if (n <= 0) {
        _pending.remove(key);
        if (identical(_tail[key], run)) _tail.remove(key);
      } else {
        _pending[key] = n;
      }
    });
  }

  void _put(String key, PrepEntry? e) {
    if (!mounted) return;
    final next = Map<String, PrepEntry>.of(state.entries);
    if (e == null) {
      next.remove(key);
    } else {
      next[key] = e;
    }
    state = PrepModel(entries: next, failed: state.failed);
  }
}

final prepControllerProvider = StateNotifierProvider<PrepController, PrepModel>((ref) {
  final me = ref.watch(currentCarrierProvider) ?? ref.read(sessionProvider).name() ?? ""; // a new sign-in starts empty
  return PrepController(ref.watch(prepServiceProvider), me);
});

/// Items of a sales order for the detail screen (SuperUser / logistique only; null = not available).
final salesOrderDetailsProvider = FutureProvider.family<SalesOrderDetails?, int>((ref, soId) async {
  final service = ref.watch(salesOrderServiceProvider);
  if (service == null || soId <= 0) return null;
  return service.fetch(soId);
});
