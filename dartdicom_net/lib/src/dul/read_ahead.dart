import 'dart:async';

import '../pdu/pdus.dart';

/// The hand-off between the DUL's reader and its consumer (blueprint F42):
/// one PDU at most waits to be taken, and the reader reads the next only
/// once it has been, so a slow consumer slows the peer.
final class ReadAhead {
  Pdu? _held;
  var _closed = false;
  Completer<void>? _arrived;
  Completer<void>? _taken;

  /// Holds [pdu] until [take] takes it. The reader awaits [vacated] first,
  /// so nothing is held already.
  void hold(Pdu pdu) {
    assert(_held == null, 'the read-ahead holds one PDU at most');
    _held = pdu;
    _wake(_arrived);
    _arrived = null;
  }

  /// Completes once nothing is held, or the read-ahead is closed.
  Future<void> vacated() async {
    while (_held != null && !_closed) {
      await (_taken ??= Completer<void>()).future;
    }
  }

  /// The held PDU, once there is one; `null` once closed with none held.
  Future<Pdu?> take() async {
    while (_held == null) {
      if (_closed) return null;
      await (_arrived ??= Completer<void>()).future;
    }
    final pdu = _held;
    _held = null;
    _wake(_taken);
    _taken = null;
    return pdu;
  }

  /// No more PDUs are coming: every waiter wakes. With [drop], a held PDU
  /// is discarded; without, it can still be taken.
  void close({required bool drop}) {
    _closed = true;
    if (drop) _held = null;
    _wake(_arrived);
    _arrived = null;
    _wake(_taken);
    _taken = null;
  }

  static void _wake(Completer<void>? waiter) {
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }
}
