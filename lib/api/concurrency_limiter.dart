import "dart:async";
import "dart:collection";

/// Runs at most [max] tasks at a time; the rest wait in FIFO order.
/// Ported from runQueued in orderContact.ts (MAX = 2) so a screen full of
/// cards cannot fire dozens of PDF downloads at once.
class ConcurrencyLimiter {
  ConcurrencyLimiter(this.max);

  final int max;
  int _active = 0;
  final Queue<void Function()> _queue = Queue<void Function()>();

  int get active => _active;

  Future<T> run<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    void start() {
      _active++;
      Future<T>.sync(task)
          .then<void>(completer.complete, onError: completer.completeError)
          .whenComplete(() {
        _active--;
        if (_queue.isNotEmpty) _queue.removeFirst()();
      });
    }

    if (_active < max) {
      start();
    } else {
      _queue.add(start);
    }
    return completer.future;
  }
}
