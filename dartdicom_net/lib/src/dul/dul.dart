import 'dart:async';
import 'dart:typed_data';

import '../errors.dart';
import '../fsm/table.dart';
import '../pdu/pdus.dart';
import '../transport/transport.dart';
import 'framer.dart';

/// The DICOM Upper Layer service for one association (PS3.8 §9): PDUs in
/// and out over a [Transport], every event checked against the state
/// machine [transitions].
///
/// One reader pulls PDUs with [receive], so nothing reorders (a DIMSE
/// response always follows the request it answers).
final class Dul {
  /// A DUL for the requestor, over a transport that just connected.
  Dul.requestor(this._transport)
      : _pdus =
            StreamIterator(_transport.incoming.transform(const PduFramer())) {
    _apply(UlEvent.evt1); // AE-1: the transport connected before this call
  }

  final Transport _transport;
  final StreamIterator<Uint8List> _pdus;
  var _state = UlState.sta1;

  /// The current state of the state machine.
  UlState get state => _state;

  /// Sends A-ASSOCIATE-RQ and waits for the answer: the A-ASSOCIATE-AC, or
  /// an [AssociationRejected] for an A-ASSOCIATE-RJ.
  Future<AssociateAc> requestAssociation(AssociateRq rq) async {
    _apply(UlEvent.evt2); // AE-2
    await _transport.send(rq.encode());
    final answer = await receive();
    return switch (answer) {
      AssociateAc() => answer,
      AssociateRj(:final result, :final source, :final reason) =>
        throw AssociationRejected(
            result: result, source: source, reason: reason),
      _ => throw StateError('receive returned $answer in Sta5'),
    };
  }

  /// Sends one P-DATA-TF (DT-1).
  Future<void> send(PDataTf pdu) {
    _apply(UlEvent.evt9);
    return _transport.send(pdu.encode());
  }

  /// The next PDU for the association layer: A-ASSOCIATE-AC/RJ (Sta5),
  /// P-DATA-TF (Sta6, Sta7) or A-RELEASE-RP (Sta7).
  ///
  /// Throws [AssociationAborted] if the peer aborts or the connection
  /// closes, and [DimseProtocolException] (after aborting) for an invalid
  /// or unexpected PDU.
  Future<Pdu> receive() async {
    while (true) {
      final Uint8List bytes;
      try {
        if (!await _pdus.moveNext()) {
          _receive(UlEvent.evt17);
          throw AssociationAborted(
              'the connection closed before the association was released');
        }
        bytes = _pdus.current;
      } on FormatException catch (e) {
        await _invalid(e.message);
      }
      final Pdu pdu;
      try {
        pdu = Pdu.decode(bytes);
      } on FormatException catch (e) {
        await _invalid(e.message);
      }
      final event = switch (pdu) {
        AssociateRq() => UlEvent.evt6,
        AssociateAc() => UlEvent.evt3,
        AssociateRj() => UlEvent.evt4,
        PDataTf() => UlEvent.evt10,
        ReleaseRq() => UlEvent.evt12,
        ReleaseRp() => UlEvent.evt13,
        Abort() => UlEvent.evt16,
      };
      final from = _state;
      switch (_receive(event)) {
        case UlAction.ae3 || UlAction.dt2 || UlAction.ar6:
          return pdu;
        case UlAction.ae4 || UlAction.ar3:
          await _transport.close();
          return pdu;
        case UlAction.aa3:
          await _transport.close();
          final abort = pdu as Abort;
          throw AssociationAborted(abort.source == 2
              ? 'the peer\'s DICOM service aborted the association '
                  '(reason ${abort.reason})'
              : 'the peer aborted the association');
        case UlAction.aa2:
          await _transport.close();
          continue;
        case UlAction.aa6:
          continue;
        case UlAction.aa8:
          await _abort(source: 2, reason: 2);
          throw DimseProtocolException('unexpected $pdu in ${from.name}');
        case final action:
          throw StateError('no handler for $action on $pdu in ${from.name}');
      }
    }
  }

  /// Sends A-RELEASE-RQ and waits for A-RELEASE-RP; the transport is then
  /// closed (AR-3). P-DATA that arrives meanwhile is discarded.
  Future<void> release() async {
    _apply(UlEvent.evt11); // AR-1
    await _transport.send(const ReleaseRq().encode());
    while (await receive() is! ReleaseRp) {}
  }

  /// Sends A-ABORT (service user) and closes the transport.
  Future<void> abort() async {
    if (_state == UlState.sta1 || _state == UlState.sta13) return;
    await _abort(source: 0, reason: 0, event: UlEvent.evt15);
  }

  Future<Never> _invalid(String problem) async {
    _receive(UlEvent.evt19);
    await _abort(source: 2, reason: 1);
    throw DimseProtocolException('invalid PDU ($problem)');
  }

  Future<void> _abort(
      {required int source, required int reason, UlEvent? event}) async {
    if (event != null) _apply(event);
    try {
      await _transport.send(Abort(source: source, reason: reason).encode());
    } on Object {
      // The connection may already be gone; closing is all that is left.
    }
    await _transport.close();
  }

  /// Applies a local request [event]; the table must define it.
  void _apply(UlEvent event) {
    final next = transitions[(_state, event)];
    if (next == null) {
      throw StateError('${event.name} is not allowed in ${_state.name}');
    }
    _state = next.$2;
  }

  /// Applies a received [event], returning the action to perform.
  UlAction _receive(UlEvent event) {
    final (action, next) = transition(_state, event);
    _state = next;
    return action;
  }
}
