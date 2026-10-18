// C-CANCEL (PRD N-07, F14): cancelling a find or get subscription sends
// C-CANCEL-RQ at once, drains to the final response (a get still storing
// what is in flight), and leaves the association free; a paused
// subscription stops reading; a peer that ignores the cancel is aborted.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import '../support/peer.dart';

const _ae = ApplicationEntity(
  aeTitle: 'DARTDICOM',
  requestedContexts: [
    ...PresentationContexts.verification,
    ...PresentationContexts.studyRootQueryRetrieve,
  ],
  retrieveStorageClasses: [SopClasses.ctImageStorage],
);

final _query = Dataset()
  ..set(DicomTags.queryRetrieveLevel, 'STUDY')
  ..setEmpty(DicomTags.studyInstanceUid);

final _instance = DicomFile.fromBytes(
        File('../fixtures/data/synthetic/ct_signed_explicit_le.dcm')
            .readAsBytesSync())
    .dataset;

Future<(Association, ScriptedPeer)> _associate(
    {Transport Function(InMemoryTransport)? wrap}) async {
  final (transport, peer) = ScriptedPeer.connect();
  unawaited(peer.accept());
  final assoc = await _ae.associateOver(wrap?.call(transport) ?? transport,
      aeTitle: 'PEER');
  return (assoc, peer);
}

Future<void> _match(ScriptedPeer peer, DimseMessage rq, int i) =>
    peer.sendMessage(DimseMessage(
        rq.contextId,
        ScriptedPeer.response(CommandField.cFindRsp, rq, 0xFF00,
            hasDataset: true),
        (Dataset()
              ..set(DicomTags.queryRetrieveLevel, 'STUDY')
              ..set(DicomTags.studyInstanceUid, '1.2.3.$i'))
            .toBytes(transferSyntax: TransferSyntaxes.explicitVrLittleEndian)));

Future<void> _final(
        ScriptedPeer peer, DimseMessage rq, int field, int status) =>
    peer.sendMessage(
        DimseMessage(rq.contextId, ScriptedPeer.response(field, rq, status)));

/// Reads a C-CANCEL-RQ for [rq] and checks it is pynetdicom's command set.
Future<void> _expectCancel(ScriptedPeer peer, DimseMessage rq) async {
  final cancel = await peer.nextMessage();
  expect(cancel.commandField, CommandField.cCancelRq);
  expect(cancel.messageIdBeingRespondedTo, rq.messageId);
  expect(cancel.contextId, rq.contextId);
  expect(cancel.command.contains(DicomTags.affectedSopClassUid), isFalse);
}

/// Answers the C-ECHO that proves the association is free again.
Future<void> _answerEcho(ScriptedPeer peer) async {
  final echo = await peer.nextMessage();
  expect(echo.commandField, CommandField.cEchoRq);
  await _final(peer, echo, CommandField.cEchoRsp, 0x0000);
}

void main() {
  test('.first on a find cancels, drains the in-flight matches, frees it',
      () async {
    final (assoc, peer) = await _associate();
    final peerSide = () async {
      final rq = await peer.nextMessage();
      await _match(peer, rq, 0);
      await _expectCancel(peer, rq);
      await _match(peer, rq, 1); // in flight: read, never emitted
      await _final(peer, rq, CommandField.cFindRsp, 0xFE00);
      await _answerEcho(peer);
    }();
    final first = await assoc.sendCFind(_query).first;
    expect(first.get(DicomTags.studyInstanceUid), '1.2.3.0');
    expect(await assoc.sendCEcho(), isA<DimseSuccess>());
    await peerSide;
  });

  test('await for … break does the same', () async {
    final (assoc, peer) = await _associate();
    final peerSide = () async {
      final rq = await peer.nextMessage();
      await _match(peer, rq, 0);
      await _expectCancel(peer, rq);
      await _final(peer, rq, CommandField.cFindRsp, 0xFE00);
      await _answerEcho(peer);
    }();
    final seen = <Dataset>[];
    await for (final match in assoc.sendCFind(_query)) {
      seen.add(match);
      break;
    }
    expect(seen, hasLength(1));
    expect(await assoc.sendCEcho(), isA<DimseSuccess>());
    await peerSide;
  });

  test('a cancelled get still stores what is in flight (decision 7)', () async {
    final (assoc, peer) = await _associate();
    final sink = MemorySink();
    final peerSide = () async {
      final rq = await peer.nextMessage();
      final storeContext = peer.contextFor(SopClasses.ctImageStorage);
      Future<void> store(int i) async {
        await peer.sendMessage(DimseMessage(
            storeContext,
            Dataset()
              ..set(DicomTags.affectedSopClassUid,
                  SopClasses.ctImageStorage.value)
              ..set(DicomTags.commandField, CommandField.cStoreRq)
              ..set(DicomTags.messageId, 100 + i)
              ..set(DicomTags.priority, 0)
              ..set(DicomTags.commandDataSetType, 0x0001)
              ..set(DicomTags.affectedSopInstanceUid,
                  _instance.require(DicomTags.sopInstanceUid)),
            _instance.toBytes(
                transferSyntax: TransferSyntaxes.explicitVrLittleEndian)));
        final rsp = await peer.nextMessage();
        expect(rsp.status, 0x0000);
      }

      await store(0);
      await peer.sendMessage(DimseMessage(
          rq.contextId,
          ScriptedPeer.response(CommandField.cGetRsp, rq, 0xFF00)
            ..set(DicomTags.numberOfRemainingSuboperations, 2)
            ..set(DicomTags.numberOfCompletedSuboperations, 1)));
      await _expectCancel(peer, rq);
      await store(1); // already on its way when the cancel came
      await peer.sendMessage(DimseMessage(
          rq.contextId,
          ScriptedPeer.response(CommandField.cGetRsp, rq, 0xFE00)
            ..set(DicomTags.numberOfRemainingSuboperations, 1)
            ..set(DicomTags.numberOfCompletedSuboperations, 2)));
      await _answerEcho(peer);
    }();
    final progress = await assoc.sendCGet(_query, sink).first;
    expect(progress.completed, 1);
    expect(sink.instances, hasLength(2));
    expect(await assoc.sendCEcho(), isA<DimseSuccess>());
    await peerSide;
  });

  test('a paused subscription stops reading from the peer', () async {
    late _Counting counting;
    final (assoc, peer) =
        await _associate(wrap: (t) => counting = _Counting(t));
    final seen = <Dataset>[];
    final finished = Completer<void>();
    final sub =
        assoc.sendCFind(_query).listen(seen.add, onDone: finished.complete);
    final rq = await peer.nextMessage();
    await _match(peer, rq, 0);
    while (seen.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    sub.pause();
    final before = counting.chunks;
    for (var i = 1; i < 8; i++) {
      await _match(peer, rq, i);
    }
    await _final(peer, rq, CommandField.cFindRsp, 0x0000);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    // A few PDUs in the stream buffers (the DUL's slot, the read in
    // progress, one in transit), never all eight the peer sent.
    expect(counting.chunks - before, lessThanOrEqualTo(3));
    sub.resume();
    await finished.future;
    expect(seen, hasLength(8));
  });

  test('a peer that ignores the cancel is aborted after the DIMSE timeout', () {
    fakeAsync((async) {
      final (transport, peer) = ScriptedPeer.connect();
      peer.accept();
      Association? assoc;
      _ae.associateOver(transport, aeTitle: 'PEER').then((a) => assoc = a);
      async.flushMicrotasks();
      final sub = assoc!.sendCFind(_query).listen((_) {});
      DimseMessage? rq;
      peer.nextMessage().then((m) => rq = m);
      async.flushMicrotasks();
      _match(peer, rq!, 0);
      async.flushMicrotasks();
      var cancelled = false;
      Object? cancelError;
      sub.cancel().then((_) {
        cancelled = true;
      }, onError: (Object e) {
        cancelError = e;
      });
      peer.nextMessage(); // the C-CANCEL-RQ, never answered
      async.elapse(const Duration(seconds: 29));
      expect(cancelled, isFalse);
      async.elapse(const Duration(seconds: 2));
      expect(cancelled, isTrue);
      expect(cancelError, isNull);
      Object? echoError;
      assoc!.sendCEcho().then((_) {}, onError: (Object e) {
        echoError = e;
      });
      async.flushMicrotasks();
      expect(echoError,
          isA<DimseTimeout>().having((e) => e.kind, 'kind', TimeoutKind.dimse));
    });
  });
}

/// Counts the chunks its consumer has taken from the peer.
final class _Counting implements Transport {
  _Counting(this._inner);

  final InMemoryTransport _inner;
  var chunks = 0;

  @override
  late final Stream<Uint8List> incoming = _inner.incoming.map((c) {
    chunks++;
    return c;
  });

  @override
  Future<void> send(Uint8List bytes) => _inner.send(bytes);

  @override
  Future<void> close() => _inner.close();
}
