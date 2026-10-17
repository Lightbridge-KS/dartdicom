import 'dart:async';
import 'dart:collection';

import 'package:dartdicom/dartdicom.dart';

import '../acse/negotiation.dart';
import '../dimse/fragments.dart';
import '../dimse/message.dart';
import '../dimse/status.dart';
import '../dul/dul.dart';
import '../errors.dart';
import '../pdu/pdus.dart';
import '../transport/transport.dart';
import 'application_entity.dart';

/// An established association with a peer AE: the DIMSE operations run
/// here, one at a time.
///
/// Get one from `ApplicationEntity.associate`; end it with [release] (or
/// [abort]). Transport, association and protocol failures throw a
/// [DimseException]; DIMSE outcomes come back as a [DimseStatus] (design
/// D3).
final class Association {
  Association._(this._dul, this.calledAeTitle, this.acceptedContexts,
      this._peerMaxPduLength);

  /// Requests an association over [transport] with [rq].
  static Future<Association> request(
      Transport transport, AssociateRq rq, ApplicationEntity ae) async {
    final dul = Dul.requestor(transport);
    final ac = await dul.requestAssociation(rq);
    return Association._(dul, rq.calledAeTitle, negotiatedContexts(rq, ac),
        ac.userInformation.maxLength);
  }

  final Dul _dul;
  final int _peerMaxPduLength;
  final _assembler = Assembler();
  final _received = Queue<DimseMessage>();
  var _lastMessageId = 0;
  var _busy = false;

  /// The peer's AE title.
  final String calledAeTitle;

  /// The presentation contexts the peer accepted.
  final List<AcceptedContext> acceptedContexts;

  /// Sends C-ECHO-RQ and returns the response's status.
  Future<DimseStatus> sendCEcho() => _exclusive(() async {
        final context = _contextFor(SopClasses.verification, 'C-ECHO');
        final id = _nextMessageId();
        await _send(DimseMessage(
            context.id,
            requestCommand(CommandField.cEchoRq, id, SopClasses.verification,
                hasDataset: false)));
        final rsp = await _responseTo(id, CommandField.cEchoRsp);
        return DimseStatus(rsp.status ?? 0xC000);
      });

  /// Releases the association gracefully (A-RELEASE) and closes the
  /// connection.
  Future<void> release() => _exclusive(_dul.release);

  /// Aborts the association (A-ABORT) and closes the connection.
  Future<void> abort() => _dul.abort();

  /// Runs [operation] alone: one DIMSE operation at a time, since no
  /// asynchronous operations window is negotiated.
  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    if (_busy) {
      throw StateError('another operation is still running on this '
          'association; await it (or cancel its stream) first');
    }
    _busy = true;
    try {
      return await operation();
    } finally {
      _busy = false;
    }
  }

  AcceptedContext _contextFor(Uid sopClass, String operation) =>
      acceptedContexts.where((c) => c.abstractSyntax == sopClass).firstOrNull ??
      (throw StateError('$operation needs an accepted presentation context '
          'for ${sopClass.value}, and the peer accepted none; propose it in '
          'ApplicationEntity.requestedContexts'));

  int _nextMessageId() =>
      _lastMessageId = _lastMessageId == 0xFFFF ? 1 : _lastMessageId + 1;

  Future<void> _send(DimseMessage message) async {
    for (final pdu in fragment(message, _peerMaxPduLength)) {
      await _dul.send(pdu);
    }
  }

  /// The next whole DIMSE message from the peer.
  Future<DimseMessage> _receive() async {
    while (_received.isEmpty) {
      final pdu = await _dul.receive();
      if (pdu is! PDataTf) {
        await _protocolAbort('unexpected $pdu during an operation');
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

  /// The next message, which must be a [field] response to request [id].
  Future<DimseMessage> _responseTo(int id, int field) async {
    final message = await _receive();
    if (message.commandField != field ||
        message.messageIdBeingRespondedTo != id) {
      await _protocolAbort('expected the response to message $id, but got '
          '$message responding to ${message.messageIdBeingRespondedTo}');
    }
    return message;
  }

  Future<Never> _protocolAbort(String problem) async {
    await _dul.abort();
    throw DimseProtocolException(problem);
  }

  @override
  String toString() => 'Association($calledAeTitle, '
      '${acceptedContexts.length} accepted contexts)';
}
