import 'dart:collection';

import '../dul/dul.dart';
import '../errors.dart';
import '../pdu/pdus.dart';
import 'fragments.dart';
import 'message.dart';

/// The DIMSE messages of one association, over its [Dul]: each message
/// fragmented to fit the peer's maximum PDU length on the way out, and
/// reassembled from P-DATA-TF PDUs on the way in (PS3.8 §9.3.5).
///
/// A protocol violation aborts the association before it is thrown, so a
/// [DimseProtocolException] always means the association is gone.
final class DimseChannel {
  DimseChannel(this._dul, this._peerMaxPduLength);

  final Dul _dul;
  final int _peerMaxPduLength;
  final _assembler = Assembler();
  final _received = Queue<DimseMessage>();

  /// Sends [message], fragmented for the peer.
  Future<void> send(DimseMessage message) async {
    for (final pdu in fragment(message, _peerMaxPduLength)) {
      await _dul.send(pdu);
    }
  }

  /// The next whole DIMSE message from the peer.
  Future<DimseMessage> receive() async {
    while (_received.isEmpty) {
      final pdu = await _dul.receive();
      if (pdu is! PDataTf) {
        await protocolAbort('unexpected $pdu during an operation');
      }
      final List<DimseMessage> messages;
      try {
        messages = _assembler.feed(pdu);
      } on DimseProtocolException {
        await _dul.abort();
        rethrow;
      }
      _received.addAll(messages);
    }
    return _received.removeFirst();
  }

  /// Aborts the association, then throws a [DimseProtocolException] saying
  /// what went wrong.
  Future<Never> protocolAbort(String problem) async {
    await _dul.abort();
    throw DimseProtocolException(problem);
  }
}
