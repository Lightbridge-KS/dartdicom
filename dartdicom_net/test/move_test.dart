// C-MOVE as SCU (PRD N-09) against a scripted peer: progress from each
// response, the S5 final-status rules, C-CANCEL, and the request itself.
import 'dart:async';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:test/test.dart';

import 'support/peer.dart';

const _ae = ApplicationEntity(
  aeTitle: 'DARTDICOM',
  requestedContexts: [
    ...PresentationContexts.verification,
    ...PresentationContexts.studyRootQueryRetrieve,
  ],
);

final _query = Dataset()
  ..set(DicomTags.queryRetrieveLevel, 'SERIES')
  ..set(DicomTags.studyInstanceUid, '1.2.3')
  ..set(DicomTags.seriesInstanceUid, '1.2.3.4');

Future<(Association, ScriptedPeer)> _associate() async {
  final (transport, peer) = ScriptedPeer.connect();
  unawaited(peer.accept());
  return (await _ae.associateOver(transport, aeTitle: 'PEER'), peer);
}

Dataset _rsp(DimseMessage rq, int status,
        {int? remaining, int completed = 0, int failed = 0, int warning = 0}) =>
    ScriptedPeer.response(CommandField.cMoveRsp, rq, status,
        hasDataset: status == 0xB000)
      ..set(DicomTags.numberOfCompletedSuboperations, completed)
      ..set(DicomTags.numberOfFailedSuboperations, failed)
      ..set(DicomTags.numberOfWarningSuboperations, warning)
      ..addIf(remaining);

extension on Dataset {
  void addIf(int? remaining) {
    if (remaining != null) {
      set(DicomTags.numberOfRemainingSuboperations, remaining);
    }
  }
}

/// A peer answering one C-MOVE with [n] pending responses and a final
/// [status]; returns the request.
Future<DimseMessage> _serve(ScriptedPeer peer, int n,
    {int status = 0x0000}) async {
  final rq = await peer.nextMessage();
  for (var i = 0; i < n; i++) {
    await peer.sendMessage(DimseMessage(rq.contextId,
        _rsp(rq, 0xFF00, remaining: n - i - 1, completed: i + 1)));
  }
  await peer.sendMessage(DimseMessage(
      rq.contextId,
      _rsp(rq, status,
          completed: status == 0 || n == 0 ? n : n - 1,
          failed: status == 0 ? 0 : 1),
      status == 0xB000
          ? (Dataset()
                ..setAll(DicomTags.failedSopInstanceUidList, ['1.2.3.4.9']))
              .toBytes(transferSyntax: TransferSyntaxes.explicitVrLittleEndian)
          : null));
  return rq;
}

void main() {
  test('the request names the destination on the Move context', () async {
    final (assoc, peer) = await _associate();
    final served = _serve(peer, 0);
    await assoc.sendCMove(_query, destination: 'DARTDICOM').drain<void>();
    final rq = await served;
    expect(rq.commandField, CommandField.cMoveRq);
    expect(rq.command.get(DicomTags.moveDestination), 'DARTDICOM');
    expect(rq.affectedSopClassUid,
        SopClasses.studyRootQueryRetrieveInformationModelMove.value);
    expect(
        Dataset.fromBytes(rq.dataset!,
                transferSyntax: TransferSyntaxes.explicitVrLittleEndian)
            .get(DicomTags.seriesInstanceUid),
        '1.2.3.4');
  });

  test('progress after each response; the last carries the final status',
      () async {
    final (assoc, peer) = await _associate();
    unawaited(_serve(peer, 3));
    final events =
        await assoc.sendCMove(_query, destination: 'DARTDICOM').toList();
    expect([for (final e in events) e.completed], [1, 2, 3, 3]);
    expect([for (final e in events) e.remaining], [2, 1, 0, null]);
    expect(events.last.status, isA<DimseSuccess>());
    expect(events.last.isFinal, isTrue);
  });

  test('a final Warning (some sub-operations failed) completes normally',
      () async {
    final (assoc, peer) = await _associate();
    unawaited(_serve(peer, 2, status: 0xB000));
    final last = await assoc.sendCMove(_query, destination: 'DARTDICOM').last;
    expect(last.status, isA<DimseWarning>());
    expect(last.failed, 1);
  });

  test('a final Failure (destination unknown) is a stream error (S5)',
      () async {
    final (assoc, peer) = await _associate();
    unawaited(_serve(peer, 0, status: 0xA801));
    final events = <RetrieveProgress>[];
    await expectLater(
        assoc.sendCMove(_query, destination: 'NOBODY').forEach(events.add),
        throwsA(isA<DimseFailureException>()
            .having((e) => e.status.code, 'status', 0xA801)));
    expect(events.single.status, isA<DimseFailure>());
  });

  test('cancelling sends C-CANCEL-RQ and frees the association', () async {
    final (assoc, peer) = await _associate();
    final peerSide = () async {
      final rq = await peer.nextMessage();
      await peer.sendMessage(DimseMessage(
          rq.contextId, _rsp(rq, 0xFF00, remaining: 5, completed: 1)));
      final cancel = await peer.nextMessage();
      expect(cancel.commandField, CommandField.cCancelRq);
      expect(cancel.messageIdBeingRespondedTo, rq.messageId);
      await peer.sendMessage(DimseMessage(
          rq.contextId, _rsp(rq, 0xFE00, remaining: 4, completed: 1)));
      final echo = await peer.nextMessage();
      await peer.sendMessage(DimseMessage(echo.contextId,
          ScriptedPeer.response(CommandField.cEchoRsp, echo, 0x0000)));
    }();
    final first = await assoc.sendCMove(_query, destination: 'DARTDICOM').first;
    expect(first.completed, 1);
    expect(await assoc.sendCEcho(), isA<DimseSuccess>());
    await peerSide;
  });

  test('a C-STORE-RQ on the move\'s own association is refused (0x0122)',
      () async {
    final (assoc, peer) = await _associate();
    final peerSide = () async {
      final rq = await peer.nextMessage();
      await peer.sendMessage(DimseMessage(
          rq.contextId,
          storeCommand(7, SopClasses.ctImageStorage.value, '1.2.3.4.5'),
          (Dataset()..set(DicomTags.sopInstanceUid, '1.2.3.4.5')).toBytes(
              transferSyntax: TransferSyntaxes.implicitVrLittleEndian)));
      final refused = await peer.nextMessage();
      await peer.sendMessage(DimseMessage(rq.contextId, _rsp(rq, 0x0000)));
      return refused;
    }();
    final events =
        await assoc.sendCMove(_query, destination: 'DARTDICOM').toList();
    final refused = await peerSide;
    expect(refused.commandField, CommandField.cStoreRsp);
    expect(refused.messageIdBeingRespondedTo, 7);
    expect(refused.status, 0x0122);
    expect(refused.affectedSopInstanceUid, '1.2.3.4.5');
    expect(events.single.status, isA<DimseSuccess>());
  });

  test('a destination that is no AE title is an ArgumentError', () async {
    final (assoc, _) = await _associate();
    for (final bad in [
      '', '   ', 'A' * 17, // empty, all spaces, too long
      r'ONE\TWO', // a backslash: it would go out as two values
      'DÄRT', 'TAB\tAE', // not printable ASCII
    ]) {
      expect(
          () => assoc.sendCMove(_query, destination: bad), throwsArgumentError,
          reason: bad);
    }
  });
}
