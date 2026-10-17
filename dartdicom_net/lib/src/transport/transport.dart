import 'dart:typed_data';

/// A byte pipe to the peer: the seam between the protocol layers and the
/// network (blueprint §5). The protocol layers never see a socket, so they
/// run in tests over [InMemoryTransport] (see `in_memory_transport.dart`).
abstract interface class Transport {
  /// Bytes from the peer, in arbitrary chunks. Single subscription; it
  /// closes when the connection does.
  Stream<Uint8List> get incoming;

  /// Sends [bytes] and completes once they are handed to the network
  /// (one PDU send is the unit of atomicity, blueprint §2).
  Future<void> send(Uint8List bytes);

  /// Closes the connection gracefully.
  Future<void> close();
}
