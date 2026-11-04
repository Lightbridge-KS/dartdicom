import 'dart:async';
import 'dart:typed_data';
import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:test/test.dart';
import '../support/peer.dart';

final query = Dataset()..set(DicomTags.queryRetrieveLevel, 'STUDY');
Future<(Association, ScriptedPeer)> connect(
    {Timeouts timeouts = const Timeouts()}) async {
  final (transport, peer) = ScriptedPeer.connect();
  unawaited(peer.accept());
  final association = await ApplicationEntity(
          aeTitle: 'CLIENT',
          requestedContexts: PresentationContexts.studyRootQueryRetrieve,
          timeouts: timeouts)
      .associateOver(transport, aeTitle: 'PEER');
  return (association, peer);
}

Future<void> response(ScriptedPeer peer, DimseMessage rq, int status,
        {int? context, Dataset? dataset}) =>
    peer.sendMessage(
        DimseMessage(
            context ?? rq.contextId,
            ScriptedPeer.response(CommandField.cFindRsp, rq, status,
                hasDataset: dataset != null),
            dataset?.toBytes(
                transferSyntax: TransferSyntaxes.explicitVrLittleEndian)),
        maxPduLength: 64);

void main() {
  test('cancel drain does not wait for a paused match listener', () async {
    final (association, peer) = await connect();
    final find = association.startCFind(query);
    final listener = find.matches.listen((_) {})..pause();
    try {
      final rq = await peer.nextMessage();
      final cancelled = find.cancel();
      await peer.nextMessage();
      await response(peer, rq, 0xFE00);
      expect((await find.done).cancellationConfirmed, isTrue);
      await cancelled.timeout(const Duration(milliseconds: 300));
    } finally {
      listener.resume();
      await listener.cancel();
      await association.abort();
    }
  });

  test('invalid Identifier decoding retains typed failure and response count',
      () async {
    final (association, peer) = await connect();
    final find = association.startCFind(query);
    final rq = await peer.nextMessage();
    // An Item Delimitation Item outside an item is a dataset parse error.
    await peer.sendMessage(DimseMessage(
        rq.contextId,
        ScriptedPeer.response(CommandField.cFindRsp, rq, 0xFF01,
            hasDataset: true),
        Uint8List.fromList([0xfe, 0xff, 0x0d, 0xe0, 0, 0, 0, 0])));
    final done = await find.done;
    expect(done.status, isNull);
    expect(done.failure, isA<DimseProtocolException>());
    expect(done.responses, 1);
    expect(done.optionalKeysUnsupported, isTrue);
    await association.closed;
  });

  test('missing Status does not fabricate a terminal Find status', () async {
    final (association, peer) = await connect();
    final find = association.startCFind(query);
    final rq = await peer.nextMessage();
    await peer.sendMessage(DimseMessage(
        rq.contextId,
        ScriptedPeer.response(CommandField.cFindRsp, rq, 0)
          ..remove(DicomTags.status)));
    final done = await find.done;
    expect(done.status, isNull);
    expect(done.failure, isA<DimseProtocolException>());
    await association.closed;
  });

  for (final badField in ['command', 'messageId']) {
    test('wrong $badField cannot become an accepted Find status', () async {
      final (association, peer) = await connect();
      final find = association.startCFind(query);
      final rq = await peer.nextMessage();
      final command = ScriptedPeer.response(
          badField == 'command' ? CommandField.cEchoRsp : CommandField.cFindRsp,
          rq,
          0);
      if (badField == 'messageId') {
        command.set(DicomTags.messageIdBeingRespondedTo, rq.messageId! + 1);
      }
      await peer.sendMessage(DimseMessage(rq.contextId, command));
      final done = await find.done;
      expect(done.status, isNull);
      expect(done.failure, isA<DimseProtocolException>());
      await association.closed;
    });
  }

  test(
      'success racing cancel remains success without cancellation confirmation',
      () async {
    final (association, peer) = await connect();
    final find = association.startCFind(query);
    final rq = await peer.nextMessage();
    final cancelled = find.cancel();
    await peer.nextMessage();
    await response(peer, rq, 0);
    await cancelled;
    final done = await find.done;
    expect(done.status, isA<DimseSuccess>());
    expect(done.cancelRequested, isTrue);
    expect(done.cancellationConfirmed, isFalse);
    await association.abort();
    expect(await find.done, same(done));
  });

  test('exact Identifier limit accepts a match and resets for the next Find',
      () async {
    final (association, peer) = await connect();
    final dataset = Dataset()..set(DicomTags.studyInstanceUid, '2.25.1');
    final length = dataset
        .toBytes(transferSyntax: TransferSyntaxes.explicitVrLittleEndian)
        .length;
    final find = association.startCFind(query, maxIdentifierBytes: length);
    final rows = find.matches.toList();
    final rq = await peer.nextMessage();
    await response(peer, rq, 0xFF00, dataset: dataset);
    await response(peer, rq, 0);
    expect((await find.done).status, isA<DimseSuccess>());
    expect((await rows).single.encodedBytes, length);
    final legacy = association.sendCFind(query).toList();
    final next = await peer.nextMessage();
    await response(peer, next, 0xFF00,
        dataset: Dataset()
          ..set(DicomTags.studyDescription, 'x' * (length + 1)));
    await response(peer, next, 0);
    expect(await legacy, hasLength(1));
    await association.abort();
  });

  test('nonpositive Identifier limits fail before dispatch', () async {
    final (association, _) = await connect();
    for (final limit in [0, -1]) {
      expect(() => association.startCFind(query, maxIdentifierBytes: limit),
          throwsArgumentError);
    }
    await association.abort();
  });

  for (final status in [0, 0xFE00, 0xA700]) {
    test('validated final $status remains available independently of rows',
        () async {
      final (association, peer) = await connect();
      final find = association.startCFind(query);
      final rows = find.matches.toList();
      final rq = await peer.nextMessage();
      await response(peer, rq, 0xFF01,
          dataset: Dataset()..set(DicomTags.studyInstanceUid, '2.25.1'));
      await response(peer, rq, status);
      final done = await find.done;
      expect(done.status!.code, status);
      expect(done.optionalKeysUnsupported, isTrue);
      expect(done.responses, 1);
      expect(done.cancellationConfirmed, status == 0xFE00);
      expect(done.cancelRequested, isFalse);
      expect(await rows, hasLength(1));
      await association.abort();
    });
  }
  test('detaching the match observer does not cancel Find', () async {
    final (association, peer) = await connect();
    final find = association.startCFind(query);
    await find.matches.listen((_) {}).cancel();
    final rq = await peer.nextMessage();
    await response(peer, rq, 0);
    expect((await find.done).cancelRequested, isFalse);
    await association.abort();
  });
  test('cancel drains and retains peer confirmation', () async {
    final (association, peer) = await connect();
    final find = association.startCFind(query);
    final rq = await peer.nextMessage();
    final cancelled = find.cancel();
    expect((await peer.nextMessage()).commandField, CommandField.cCancelRq);
    await response(peer, rq, 0xFE00);
    await cancelled;
    final done = await find.done;
    expect(done.cancelRequested, isTrue);
    expect(done.cancellationConfirmed, isTrue);
    await association.abort();
  });
  test('ignored cancel yields timeout, never false confirmation', () async {
    final (association, peer) = await connect(
        timeouts: const Timeouts(dimse: Duration(milliseconds: 50)));
    final find = association.startCFind(query);
    await peer.nextMessage();
    final cancelled = find.cancel();
    await peer.nextMessage();
    await cancelled;
    final done = await find.done;
    expect(done.cancellationConfirmed, isFalse);
    expect(done.failure, isA<DimseTimeout>());
    await association.closed;
  });
  test('wrong response context cannot establish a terminal status', () async {
    final (association, peer) = await connect();
    final find = association.startCFind(query);
    final rq = await peer.nextMessage();
    await response(peer, rq, 0, context: rq.contextId + 2);
    final done = await find.done;
    expect(done.status, isNull);
    expect(done.failure, isA<DimseProtocolException>());
    await association.closed;
  });
  test('reassembly byte limit rejects a fragmented Identifier', () async {
    final (association, peer) = await connect();
    final find = association.startCFind(query, maxIdentifierBytes: 64);
    final rq = await peer.nextMessage();
    unawaited(response(peer, rq, 0xFF00,
            dataset: Dataset()..set(DicomTags.studyDescription, 'x' * 256))
        .catchError((Object _) {}));
    expect((await find.done).failure, isA<DimseIdentifierTooLarge>());
    await association.closed;
  });
  test('charset support reporting does not promise code extensions', () {
    for (final value in ['', 'ISO_IR 6', 'ISO_IR 100', 'ISO_IR 192']) {
      expect(characterSetSupport([value]), CharacterSetSupport.supported);
    }
    expect(
        characterSetSupport(['ISO_IR 166']), CharacterSetSupport.unsupported);
    expect(characterSetSupport(['ISO 2022 IR 100']),
        CharacterSetSupport.unsupported);
    expect(characterSetSupport(['ISO_IR 100', 'ISO_IR 192']),
        CharacterSetSupport.unsupported);
  });
}
