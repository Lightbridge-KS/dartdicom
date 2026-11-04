part of 'association.dart';

/// One validated pending response and its decoded Identifier.
///
/// Dataset ownership passes to the data consumer;
/// it is never part of the payload-free association observation contract.
final class FindMatch {
  const FindMatch(this.dataset, this.status, this.encodedBytes);
  final Dataset dataset;
  final DimseStatus status;
  final int encodedBytes;
}

/// Validated terminal protocol evidence, available even after cancellation.
///
/// Transport cleanup is separate: release/abort and await Association.closed.
final class FindCompletion {
  const FindCompletion(
      {this.status,
      this.failure,
      required this.cancelRequested,
      required this.responses,
      required this.optionalKeysUnsupported});
  final DimseStatus? status;

  /// An execution failure, independent of a final DIMSE failure status.
  final DimseException? failure;
  final bool cancelRequested, optionalKeysUnsupported;
  final int responses;
  bool get cancellationConfirmed => status is DimseCancel;
}

/// Owns a Find independently of presentation listeners.
///
/// Attach a match listener immediately. Detached listeners do not retain rows.
final class FindOperation {
  FindOperation._(Stream<FindMatch> source, this._lifecycle) {
    _subscription = source.listen(_matches.add,
        onError: (Object _, StackTrace __) {}, onDone: () => _matches.close());
  }
  final _FindLifecycle _lifecycle;
  final _matches = StreamController<FindMatch>.broadcast(sync: true);
  late final StreamSubscription<FindMatch> _subscription;
  Future<void>? _cancelling;

  /// Non-replayed notifications; multiple listeners share each mutable Dataset.
  Stream<FindMatch> get matches => _matches.stream;

  /// The retained result, including typed peer/protocol failures.
  ///
  /// Local configuration or API misuse, such as a missing presentation context
  /// or another active operation, can instead complete this future with an error.
  Future<FindCompletion> get done => _lifecycle.done.future;

  /// Requests C-CANCEL and awaits the bounded drain. Inspect done for proof;
  /// normal completion of this future is not peer cancellation confirmation.
  Future<void> cancel() {
    if (_lifecycle.done.isCompleted) return Future.value();
    _lifecycle.cancelRequested = true;
    return _cancelling ??= _subscription.cancel().whenComplete(() {
      // A paused presentation subscription may delay its own close event; it
      // must not extend the network cancellation/drain future.
      unawaited(_matches.close());
    });
  }
}

final class _FindLifecycle {
  final done = Completer<FindCompletion>();
  DimseStatus? status;
  Object? error;
  StackTrace? stack;
  bool cancelRequested = false, optionalKeysUnsupported = false;
  int responses = 0;
  void response(DimseStatus value) {
    if (value is DimsePending) {
      responses++;
      optionalKeysUnsupported |= value.code == 0xFF01;
    } else {
      status = value;
    }
  }

  void fail(Object value, StackTrace trace) {
    error = value;
    stack = trace;
  }

  void finish() {
    if (done.isCompleted) return;
    final failure = error;
    if (failure != null && failure is! DimseException) {
      done.completeError(failure, stack);
    } else {
      done.complete(FindCompletion(
          status: status,
          failure: failure as DimseException?,
          cancelRequested: cancelRequested,
          responses: responses,
          optionalKeysUnsupported: optionalKeysUnsupported));
    }
  }
}
