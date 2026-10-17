import 'dart:async';
import 'dart:typed_data';

import 'transport.dart';

/// Two connected in-memory transports: what one sends, the other receives.
/// For tests of both ends in one process, with no sockets.
final class InMemoryTransport implements Transport {
  InMemoryTransport._(this._in, this._out);

  /// A connected pair: `(a, b)`.
  static (InMemoryTransport, InMemoryTransport) pair() {
    final aToB = StreamController<Uint8List>();
    final bToA = StreamController<Uint8List>();
    return (InMemoryTransport._(bToA, aToB), InMemoryTransport._(aToB, bToA));
  }

  final StreamController<Uint8List> _in;
  final StreamController<Uint8List> _out;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> send(Uint8List bytes) async {
    if (_out.isClosed) throw StateError('the transport is closed');
    _out.add(Uint8List.fromList(bytes));
  }

  /// Closes the sending side; the peer sees its stream end. It doesn't wait
  /// for the peer to read that (a paused reader never would).
  @override
  Future<void> close() async {
    if (!_out.isClosed) unawaited(_out.close());
  }
}
