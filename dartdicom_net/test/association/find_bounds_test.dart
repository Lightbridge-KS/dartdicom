import 'dart:async';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dimse/fragments.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:test/test.dart';

import '../support/peer.dart';

final class _StalledWrite implements Transport {
  _StalledWrite(this.inner);
  final Transport inner;
  final blocked = Completer<void>();
  final unblock = Completer<void>();

  @override
  Stream<Uint8List> get incoming => inner.incoming;

  @override
  Future<void> send(Uint8List bytes) async {
    await inner.send(bytes);
    if (bytes.first == 0x04 && !blocked.isCompleted) {
      blocked.complete();
      await unblock.future;
    }
  }

  @override
  Future<void> close() => inner.close();
}

final _query = Dataset()..set(DicomTags.queryRetrieveLevel, 'STUDY');

Future<(Association, ScriptedPeer)> _associate(
    {Transport Function(Transport)? wrap,
    Timeouts timeouts = const Timeouts()}) async {
  final (transport, peer) = ScriptedPeer.connect();
  final serving = peer.accept();
  final association = await ApplicationEntity(
          aeTitle: 'CLIENT',
          requestedContexts: PresentationContexts.studyRootQueryRetrieve,
          timeouts: timeouts)
      .associateOver(wrap?.call(transport) ?? transport, aeTitle: 'PEER');
  await serving;
  return (association, peer);
}

List<Pdv> _pending(DimseMessage request, int status, Dataset identifier) => [
      for (final pdu in fragment(
          DimseMessage(
              request.contextId,
              ScriptedPeer.response(CommandField.cFindRsp, request, status,
                  hasDataset: true),
              identifier.toBytes(
                  transferSyntax: TransferSyntaxes.explicitVrLittleEndian)),
          64))
        ...pdu.pdvs,
    ];

void main() {
  test('legacy Find preserves multiple valid responses sharing one PDU',
      () async {
    final (association, peer) = await _associate();
    final rows = association.sendCFind(_query).toList();
    final request = await peer.nextMessage();
    final last = DimseMessage(request.contextId,
        ScriptedPeer.response(CommandField.cFindRsp, request, 0));
    await peer.send(PDataTf([
      ..._pending(request, 0xFF00,
          Dataset()..set(DicomTags.studyInstanceUid, '2.25.1')),
      ..._pending(request, 0xFF00,
          Dataset()..set(DicomTags.studyInstanceUid, '2.25.2')),
      for (final pdu in fragment(last, 64)) ...pdu.pdvs,
    ]));
    expect((await rows).map((r) => r.get(DicomTags.studyInstanceUid)),
        ['2.25.1', '2.25.2']);
    await association.abort();
    await association.closed;
  });

  for (final peerAborts in [false, true]) {
    test('cancel bounds a stalled write and retains earlier abort: $peerAborts',
        () async {
      late _StalledWrite transport;
      final (association, peer) = await _associate(
          wrap: (inner) => transport = _StalledWrite(inner),
          timeouts: const Timeouts(dimse: Duration(milliseconds: 25)));
      final find = association.startCFind(_query);
      await transport.blocked.future;
      if (peerAborts) {
        await peer.send(const Abort(source: 2, reason: 2));
        await association.closed;
      }
      try {
        await find.cancel().timeout(const Duration(milliseconds: 300));
        final completion = await find.done;
        expect(completion.cancelRequested, isTrue);
        expect(completion.cancellationConfirmed, isFalse);
        expect(completion.status, isNull);
        if (peerAborts) {
          expect(completion.failure,
              isA<AssociationAborted>().having((e) => e.source, 'source', 2));
        } else {
          expect(completion.failure, isA<DimseTimeout>());
        }
        // A later call on the ended association must not queue behind the
        // foreign transport's still-pending send future.
        final retry = association.startCFind(_query);
        final retried =
            await retry.done.timeout(const Duration(milliseconds: 300));
        expect(retried.failure, same(completion.failure));
      } finally {
        // Late write errors must be consumed after the bounded operation ends.
        transport.unblock
            .completeError(StateError('late synthetic write error'));
        await find.done;
        await association.closed;
      }
    });
  }

  for (final oversized in [true, false]) {
    test(
        'retain a completed match before a later PDU error: oversize=$oversized',
        () async {
      final (association, peer) = await _associate();
      final find = association.startCFind(_query, maxIdentifierBytes: 64);
      final matches = find.matches.toList();
      final request = await peer.nextMessage();
      final first = _pending(request, 0xFF01,
          Dataset()..set(DicomTags.studyInstanceUid, '2.25.1'));
      final tail = oversized
          ? _pending(request, 0xFF00,
              Dataset()..set(DicomTags.studyDescription, 'x' * 256))
          : [
              Pdv(request.contextId, Uint8List(1),
                  isCommand: false, isLast: true),
            ];
      await peer.send(PDataTf([...first, ...tail]));
      final completion = await find.done;
      expect(completion.status, isNull);
      expect(completion.responses, 1);
      expect(completion.optionalKeysUnsupported, isTrue);
      expect(
          completion.failure,
          oversized
              ? isA<DimseIdentifierTooLarge>()
              : isA<DimseProtocolException>());
      expect((await matches).single.dataset.get(DicomTags.studyInstanceUid),
          '2.25.1');
      await association.closed;
    });
  }
}
