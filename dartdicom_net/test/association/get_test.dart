// C-GET against a scripted peer: C-STORE sub-operations on the same
// association, progress events, the S5 final-status rules, sink failures.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:test/test.dart';

import '../support/peer.dart';

const _ae = ApplicationEntity(
  aeTitle: 'DARTDICOM',
  requestedContexts: PresentationContexts.studyRootQueryRetrieve,
  retrieveStorageClasses: [SopClasses.ctImageStorage],
);

final _query = Dataset()
  ..set(DicomTags.queryRetrieveLevel, 'SERIES')
  ..set(DicomTags.studyInstanceUid, '1.2.3')
  ..set(DicomTags.seriesInstanceUid, '1.2.3.4');

/// The instance bytes a peer sends: a fixture, in the context's syntax.
final _instance = DicomFile.fromBytes(
        File('../fixtures/data/synthetic/ct_signed_explicit_le.dcm')
            .readAsBytesSync())
    .dataset;

Future<(Association, ScriptedPeer)> _associate() async {
  final (transport, peer) = ScriptedPeer.connect();
  unawaited(peer.accept());
  return (await _ae.associateOver(transport, aeTitle: 'PEER'), peer);
}

/// A peer answering one C-GET: [instances] C-STORE sub-operations, each
/// followed by a pending C-GET-RSP, then a final [status] with no
/// remaining count. Returns the statuses of our C-STORE responses.
Future<List<int>> _serve(ScriptedPeer peer, int instances,
    {int status = 0x0000, bool finalIdentifier = false}) async {
  final rq = await peer.nextMessage();
  final storeContext = peer.contextFor(SopClasses.ctImageStorage);
  final statuses = <int>[];
  for (var i = 0; i < instances; i++) {
    final store = Dataset()
      ..set(DicomTags.affectedSopClassUid, SopClasses.ctImageStorage.value)
      ..set(DicomTags.commandField, CommandField.cStoreRq)
      ..set(DicomTags.messageId, 100 + i) // the peer's own ID space
      ..set(DicomTags.priority, 0)
      ..set(DicomTags.commandDataSetType, 0x0001)
      ..set(DicomTags.affectedSopInstanceUid,
          _instance.require(DicomTags.sopInstanceUid));
    await peer.sendMessage(
        DimseMessage(
            storeContext,
            store,
            _instance.toBytes(
                transferSyntax: TransferSyntaxes.explicitVrLittleEndian)),
        maxPduLength: 1024);
    final rsp = await peer.nextMessage();
    expect(rsp.commandField, CommandField.cStoreRsp);
    expect(rsp.contextId, storeContext);
    expect(rsp.messageIdBeingRespondedTo, 100 + i);
    statuses.add(rsp.status!);
    final pending = ScriptedPeer.response(CommandField.cGetRsp, rq, 0xFF00)
      ..set(DicomTags.numberOfRemainingSuboperations, instances - i - 1)
      ..set(DicomTags.numberOfCompletedSuboperations, i + 1)
      ..set(DicomTags.numberOfFailedSuboperations, 0)
      ..set(DicomTags.numberOfWarningSuboperations, 0);
    await peer.sendMessage(DimseMessage(rq.contextId, pending));
  }
  final last = ScriptedPeer.response(CommandField.cGetRsp, rq, status,
      hasDataset: finalIdentifier)
    ..set(DicomTags.numberOfCompletedSuboperations, instances)
    ..set(DicomTags.numberOfFailedSuboperations, status == 0 ? 0 : 1)
    ..set(DicomTags.numberOfWarningSuboperations, 0);
  final failedList = Dataset()
    ..setAll(DicomTags.failedSopInstanceUidList, ['1.2.3.4.5']);
  await peer.sendMessage(DimseMessage(
      rq.contextId,
      last,
      finalIdentifier
          ? failedList.toBytes(
              transferSyntax: TransferSyntaxes.explicitVrLittleEndian)
          : null));
  return statuses;
}

void main() {
  test('two sub-operations reach the sink, with progress after each', () async {
    final (assoc, peer) = await _associate();
    final served = _serve(peer, 2);
    final sink = MemorySink();
    final progress = await assoc.sendCGet(_query, sink).toList();

    expect(await served, [0x0000, 0x0000]);
    expect(sink.instances, hasLength(2));
    final received = sink.instances.first;
    expect(received.sopClassUid, SopClasses.ctImageStorage);
    expect(received.transferSyntax, TransferSyntaxes.explicitVrLittleEndian);
    expect(received.sourceAeTitle, 'PEER');
    expect(received.parse().get(DicomTags.rows), _instance.get(DicomTags.rows));

    expect([for (final p in progress) p.remaining], [1, 0, null]);
    expect(progress.last.status, isA<DimseSuccess>());
    expect((progress.last.completed, progress.last.total), (2, 2));
  });

  test('a final Warning with a Failed SOP Instance UID List completes',
      () async {
    final (assoc, peer) = await _associate();
    unawaited(_serve(peer, 1, status: 0xB000, finalIdentifier: true));
    final progress = await assoc.sendCGet(_query, MemorySink()).toList();
    expect(progress.last.status, isA<DimseWarning>());
    expect(progress.last.failed, 1);
  });

  test('a final Failure is delivered, then a stream error (S5)', () async {
    final (assoc, peer) = await _associate();
    unawaited(_serve(peer, 1, status: 0xA702));
    final events = <RetrieveProgress>[];
    await expectLater(assoc.sendCGet(_query, MemorySink()).forEach(events.add),
        throwsA(isA<DimseFailureException>()));
    expect(events.last.status, isA<DimseFailure>());
  });

  test('cancelling on the final progress leaves the association open',
      () async {
    final (assoc, peer) = await _associate();
    unawaited(_serve(peer, 1));
    final last =
        await assoc.sendCGet(_query, MemorySink()).firstWhere((p) => p.isFinal);
    expect(last.status, isA<DimseSuccess>());
    // An abort would reach the peer instead of the release request.
    final released = peer.acceptRelease();
    await assoc.release();
    await released;
  });

  test('after a final Failure the association is free for the next operation',
      () async {
    final (assoc, peer) = await _associate();
    unawaited(_serve(peer, 1, status: 0xA702));
    await expectLater(assoc.sendCGet(_query, MemorySink()).drain<void>(),
        throwsA(isA<DimseFailureException>()));
    final released = peer.acceptRelease();
    await assoc.release();
    await released;
  });

  test('a sink that throws fails that instance, and the retrieve goes on',
      () async {
    final (assoc, peer) = await _associate();
    final served = _serve(peer, 2);
    final progress =
        await assoc.sendCGet(_query, _FlakySink(failFirst: true)).toList();
    expect(await served, [0xC211, 0x0000]);
    expect(progress.last.isFinal, isTrue);
  });

  test('without an accepted SCP role, sub-operations are refused (0x0122)',
      () async {
    final (transport, peer) = ScriptedPeer.connect();
    unawaited(() async {
      final rq = peer.request = await peer.next() as AssociateRq;
      await peer.send(acWithoutRoles(rq));
    }());
    final assoc = await _ae.associateOver(transport, aeTitle: 'PEER');
    expect(assoc.acceptedContexts.last.scpRole, isFalse);
    final served = _serve(peer, 1);
    final sink = MemorySink();
    await assoc.sendCGet(_query, sink).toList();
    expect(await served, [0x0122]);
    expect(sink.instances, isEmpty);
  });
}

final class _FlakySink implements InstanceSink {
  _FlakySink({required this.failFirst});

  bool failFirst;

  @override
  Future<void> accept(ReceivedInstance instance) async {
    if (failFirst) {
      failFirst = false;
      throw const FileSystemException('disk full');
    }
  }
}
