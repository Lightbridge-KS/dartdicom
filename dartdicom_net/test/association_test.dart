// Associate, C-ECHO, release and the failure paths, against a scripted peer
// over an in-memory transport: no sockets.
import 'dart:async';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:test/test.dart';

import 'support/peer.dart';

const _ae = ApplicationEntity(
    aeTitle: 'DARTDICOM', requestedContexts: PresentationContexts.verification);

void main() {
  test('associate, C-ECHO, release', () async {
    final (transport, peer) = ScriptedPeer.connect();
    final peerDone = () async {
      await peer.accept();
      final rq = await peer.nextMessage();
      expect(rq.commandField, CommandField.cEchoRq);
      expect(rq.affectedSopClassUid, SopClasses.verification.value);
      await peer.sendMessage(DimseMessage(rq.contextId,
          ScriptedPeer.response(CommandField.cEchoRsp, rq, 0x0000)));
      await peer.acceptRelease();
    }();

    final assoc = await _ae.associateOver(transport, aeTitle: 'PEER');
    expect(assoc.acceptedContexts.single.transferSyntax,
        TransferSyntaxes.explicitVrLittleEndian);
    expect(await assoc.sendCEcho(), isA<DimseSuccess>());
    await assoc.release();
    await peerDone;
  });

  test('a rejection throws AssociationRejected with a reason that teaches',
      () async {
    final (transport, peer) = ScriptedPeer.connect();
    unawaited(() async {
      await peer.next();
      await peer.send(const AssociateRj(result: 1, source: 1, reason: 7));
      await peer.transport.close();
    }());
    expect(
        _ae.associateOver(transport, aeTitle: 'WRONG'),
        throwsA(isA<AssociationRejected>().having((e) => e.message, 'message',
            contains('called AE title not recognized'))));
  });

  test('a peer abort fails the operation with AssociationAborted', () async {
    final (transport, peer) = ScriptedPeer.connect();
    unawaited(() async {
      await peer.accept();
      await peer.nextMessage();
      await peer.send(const Abort(source: 0, reason: 0));
      await peer.transport.close();
    }());
    final assoc = await _ae.associateOver(transport, aeTitle: 'PEER');
    expect(assoc.sendCEcho(), throwsA(isA<AssociationAborted>()));
  });

  test('a closed connection fails the operation with AssociationAborted',
      () async {
    final (transport, peer) = ScriptedPeer.connect();
    unawaited(() async {
      await peer.accept();
      await peer.nextMessage();
      await peer.transport.close();
    }());
    final assoc = await _ae.associateOver(transport, aeTitle: 'PEER');
    expect(assoc.sendCEcho(), throwsA(isA<AssociationAborted>()));
  });

  test('a response to the wrong message ID is a protocol abort', () async {
    final (transport, peer) = ScriptedPeer.connect();
    final aborted = () async {
      await peer.accept();
      final rq = await peer.nextMessage();
      final wrong = ScriptedPeer.response(CommandField.cEchoRsp, rq, 0)
        ..set(DicomTags.messageIdBeingRespondedTo, rq.messageId! + 7);
      await peer.sendMessage(DimseMessage(rq.contextId, wrong));
      return peer.next();
    }();
    final assoc = await _ae.associateOver(transport, aeTitle: 'PEER');
    await expectLater(
        assoc.sendCEcho(), throwsA(isA<DimseProtocolException>()));
    expect(await aborted, isA<Abort>());
  });

  test('a second operation while one runs is a StateError', () async {
    final (transport, peer) = ScriptedPeer.connect();
    unawaited(() async {
      await peer.accept();
      final rq = await peer.nextMessage();
      await peer.sendMessage(DimseMessage(
          rq.contextId, ScriptedPeer.response(CommandField.cEchoRsp, rq, 0)));
    }());
    final assoc = await _ae.associateOver(transport, aeTitle: 'PEER');
    final first = assoc.sendCEcho();
    expect(assoc.sendCEcho, throwsStateError);
    expect(await first, isA<DimseSuccess>());
  });

  test('an operation with no accepted context is a StateError that says why',
      () async {
    final (transport, peer) = ScriptedPeer.connect();
    unawaited(peer.accept());
    final assoc = await const ApplicationEntity(aeTitle: 'DARTDICOM')
        .associateOver(transport, aeTitle: 'PEER');
    expect(
        assoc.sendCEcho,
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('requestedContexts'))));
  });

  group('DimseStatus classifies by PS3.7 Annex C', () {
    test('success, pending, warning, cancel, failure', () {
      expect(DimseStatus(0x0000), isA<DimseSuccess>());
      expect(DimseStatus(0xFF00), isA<DimsePending>());
      expect(DimseStatus(0xB000), isA<DimseWarning>());
      expect(DimseStatus(0x0107), isA<DimseWarning>());
      expect(DimseStatus(0xFE00), isA<DimseCancel>());
      expect(DimseStatus(0xA700), isA<DimseFailure>());
      expect(DimseStatus(0xC211), isA<DimseFailure>());
    });

    test('orThrow throws only for a failure', () {
      expect(DimseStatus(0xB000).orThrow(), isA<DimseWarning>());
      expect(() => DimseStatus(0xA700).orThrow(),
          throwsA(isA<DimseFailureException>()));
    });
  });
}
