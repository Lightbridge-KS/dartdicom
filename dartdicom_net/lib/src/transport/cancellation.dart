import 'dart:async';
import '../errors.dart';

/// One caller-owned cancellation signal, usable before TCP establishment.
/// A cancelled signal is never reused for another attempt.
final class AssociationCancellation {
  final Completer<void> _signal = Completer<void>();
  bool get isCancelled => _signal.isCompleted;
  Future<void> get whenCancelled => _signal.future;
  void cancel() {
    if (!isCancelled) _signal.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) {
      throw AssociationAborted('locally cancelled', locallyCancelled: true);
    }
  }
}
