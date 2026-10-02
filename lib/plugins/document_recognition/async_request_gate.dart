import 'dart:async';
import 'dart:collection';

/// Small FIFO semaphore for scarce recognition resources.
///
/// A two-page spread should not turn into two simultaneous remote VLM requests:
/// that only creates model-side queueing and makes the second page flaky.
class AsyncRequestGate {
  AsyncRequestGate(this._permits) : assert(_permits > 0);

  int _permits;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      return await action();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_permits > 0) {
      _permits--;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.addLast(waiter);
    return waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
      return;
    }
    _permits++;
  }
}
