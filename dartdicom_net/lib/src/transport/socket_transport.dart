import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'transport.dart';

/// A [Transport] over a TCP [Socket]: the only `dart:io` the association
/// path touches (blueprint §4, I-6).
final class SocketTransport implements Transport {
  SocketTransport(this._socket) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
  }

  /// Connects to [host]:[port].
  static Future<SocketTransport> connect(String host, int port,
          {Duration? timeout}) async =>
      SocketTransport(await Socket.connect(host, port, timeout: timeout));

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
