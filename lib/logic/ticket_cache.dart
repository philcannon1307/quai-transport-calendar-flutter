/// In-memory picking-ticket cache. Ported from the reference app: 10-minute TTL
/// so reopening the same ticket is instant but a stale PDF never lingers.
class TicketCache {
  TicketCache({this.ttl = const Duration(minutes: 10), DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _clock;
  final Map<String, _Entry> _entries = <String, _Entry>{};

  List<int>? get(String orderNum) {
    final e = _entries[orderNum];
    if (e == null) return null;
    if (_clock().difference(e.at) >= ttl) {
      _entries.remove(orderNum);
      return null;
    }
    return e.bytes;
  }

  void put(String orderNum, List<int> bytes) => _entries[orderNum] = _Entry(bytes, _clock());

  void clear() => _entries.clear();
}

class _Entry {
  const _Entry(this.bytes, this.at);
  final List<int> bytes;
  final DateTime at;
}
