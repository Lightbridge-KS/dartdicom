import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../timeouts.dart';
import '../errors.dart';
import 'cancellation.dart';
import 'transport.dart';

/// A [Transport] over a TCP [Socket]: the only `dart:io` the association
/// path touches (blueprint §4, I-6).
final class SocketTransport implements AbortableTransport {
  SocketTransport(this._socket) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
  }

  /// Connects to [host]:[port]. Throws a [DimseTimeout] after [timeout],
  /// and a `SocketException` if the host refuses or can't be reached.
  static Future<SocketTransport> connect(String host, int port,
      {Duration timeout = const Duration(seconds: 30),
      AssociationCancellation? cancellation}) async {
    cancellation?.throwIfCancelled();
    final result = Completer<SocketTransport>();
    ConnectionTask<Socket>? task;
    void fail(Object error) {
      task?.cancel();
      if (!result.isCompleted) result.completeError(error);
    }

    final timer =
        Timer(timeout, () => fail(DimseTimeout(TimeoutKind.connect, timeout)));
    unawaited(cancellation?.whenCancelled.then((_) {
      if (!result.isCompleted) {
        fail(AssociationAborted('locally cancelled', locallyCancelled: true));
      }
    }));
    // Also bound name resolution / startConnect itself, and destroy late sockets.
    unawaited(() async {
      try {
        task = await Socket.startConnect(host, port);
        if (result.isCompleted) {
          task!.cancel();
          // Still await the task future: cancellation can complete it with an
          // error, or a socket can win the race and must be destroyed below.
        }
        final socket = await task!.socket;
        if (result.isCompleted || (cancellation?.isCancelled ?? false)) {
          socket.destroy();
          if (!result.isCompleted) {
            fail(AssociationAborted('locally cancelled',
                locallyCancelled: true));
          }
        } else {
          result.complete(SocketTransport(socket));
        }
      } on Object catch (error) {
        fail(error);
      }
    }());
    try {
      return await result.future;
    } finally {
      timer.cancel();
    }
  }

  /// Immediately tears down this owned socket; does not wait for queued writes.
  @override
  void destroy() => _socket.destroy();

  final Socket _socket;
  Future<void> _queue = Future.value();

  @override
  Stream<Uint8List> get incoming => _socket;

  /// Sends are queued, so PDUs never interleave on the wire.
  @override
  Future<void> send(Uint8List bytes) => _queue = _queue.then((_) {
        _socket.add(bytes);
        return _socket.flush();
      });

  @override
  Future<void> close() async {
    try {
      await _queue;
    } finally {
      await _socket.close();
    }
  }
}
