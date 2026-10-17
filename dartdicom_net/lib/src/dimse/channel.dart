import 'dart:async';
import 'dart:collection';

import '../dul/dul.dart';
import '../timeouts.dart';
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

  /// The DIMSE timeout: how long each wait for the peer's next PDU may
  /// take while an operation runs.
  Duration get _dimse => _dul.timeouts.dimse;
  final int _peerMaxPduLength;
  final _assembler = Assembler();
  final _received = Queue<DimseMessage>();
  Future<void> _sending = Future.value();

  /// Sends [message], fragmented for the peer. Messages go out whole, in
  /// the order sent: a C-CANCEL-RQ never lands between another message's
  /// PDUs (PS3.8 §9.3.5).
  Future<void> send(DimseMessage message) {
    final sent = _sending.then((_) async {
      for (final pdu in fragment(message, _peerMaxPduLength)) {
        await _dul.send(pdu);
      }
    });
    _sending = sent.then((_) {}, onError: (Object _) {});
    return sent;
  }

  /// The next whole DIMSE message from the peer. Each wait for a PDU is
  /// bounded by the DIMSE timeout, unless [timed] is false (an acceptor
  /// waiting for its next request, which the network timer bounds).
  Future<DimseMessage> receive({bool timed = true}) async {
    while (_received.isEmpty) {
      final timer = timed
          ? Timer(
              _dimse,
              () => unawaited(
                  _dul.abort(because: DimseTimeout(TimeoutKind.dimse, _dimse))))
          : null;
      final Pdu? pdu;
      try {
        pdu = await _dul.receive();
      } finally {
        timer?.cancel();
      }
      if (pdu == null) {
        throw AssociationAborted('the peer released the association');
      }
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
