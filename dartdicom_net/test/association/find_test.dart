// C-FIND against a scripted peer: matches as a stream, the S5 final-status
// rules, and the wire edge cases (several PDVs per PDU, fragmented data).
import 'dart:async';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:test/test.dart';

import '../support/peer.dart';

const _ae = ApplicationEntity(
    aeTitle: 'DARTDICOM',
    requestedContexts: PresentationContexts.studyRootQueryRetrieve);

final _query = Dataset()
  ..set(DicomTags.queryRetrieveLevel, 'STUDY')
  ..set(DicomTags.patientId, 'P001')
  ..setEmpty(DicomTags.studyInstanceUid);

/// A peer that answers one C-FIND with [matches] pending responses and a
/// final [status]. Returns the request it received.
Future<DimseMessage> _answer(ScriptedPeer peer, int matches,
    {int status = 0x0000, int maxPduLength = 16384, int pdvsPerPdu = 1}) async {
  final rq = await peer.nextMessage();
  final ts = peer.request!.contexts
      .firstWhere((c) => c.id == rq.contextId)
      .transferSyntaxes
      .first;
  for (var i = 0; i < matches; i++) {
    final match = Dataset()
      ..set(DicomTags.queryRetrieveLevel, 'STUDY')
      ..set(DicomTags.studyInstanceUid, '1.2.3.$i')
      ..set(DicomTags.studyDescription, 'Study $i ${'x' * 200}');
    await peer.sendMessage(
        DimseMessage(
            rq.contextId,
            ScriptedPeer.response(CommandField.cFindRsp, rq, 0xFF00,
                hasDataset: true),
            match.toBytes(transferSyntax: Uid(ts))),
        maxPduLength: maxPduLength,
        pdvsPerPdu: pdvsPerPdu);
  }
  await peer.sendMessage(DimseMessage(
      rq.contextId, ScriptedPeer.response(CommandField.cFindRsp, rq, status)));
  return rq;
}

Future<(Association, ScriptedPeer)> _associate() async {
  final (transport, peer) = ScriptedPeer.connect();
  unawaited(peer.accept());
  return (await _ae.associateOver(transport, aeTitle: 'PEER'), peer);
}

void main() {
  for (final n in [0, 1, 5]) {
    test('$n matches arrive as $n datasets, then the stream completes',
        () async {
      final (assoc, peer) = await _associate();
      final rq = _answer(peer, n);
      final matches = await assoc.sendCFind(_query).toList();
      expect([for (final m in matches) m.get(DicomTags.studyInstanceUid)],
          [for (var i = 0; i < n; i++) '1.2.3.$i']);
      final request = await rq;
      expect(request.affectedSopClassUid,
          SopClasses.studyRootQueryRetrieveInformationModelFind.value);
      final sent = Dataset.fromBytes(request.dataset!,
          transferSyntax: TransferSyntaxes.explicitVrLittleEndian);
      expect(sent.get(DicomTags.patientId), 'P001');
      expect(sent.contains(DicomTags.studyInstanceUid), isTrue);
    });
  }

  test('several PDVs in one P-DATA-TF are all read', () async {
    final (assoc, peer) = await _associate();
    unawaited(_answer(peer, 3, pdvsPerPdu: 4));
    expect(await assoc.sendCFind(_query).length, 3);
  });

  test('a dataset fragmented across many PDUs is reassembled', () async {
    final (assoc, peer) = await _associate();
    unawaited(_answer(peer, 2, maxPduLength: 64));
    final matches = await assoc.sendCFind(_query).toList();
    expect(
        matches.last.get(DicomTags.studyDescription), startsWith('Study 1 '));
  });

  test('a Warning final status completes normally', () async {
    final (assoc, peer) = await _associate();
    unawaited(_answer(peer, 1, status: 0xB000));
    expect(await assoc.sendCFind(_query).length, 1);
  });

  test('a Failure final status is a stream error, never "no matches" (S5)',
      () async {
    final (assoc, peer) = await _associate();
    unawaited(_answer(peer, 0, status: 0xA700));
    await expectLater(
        assoc.sendCFind(_query).toList(),
        throwsA(isA<DimseFailureException>()
            .having((e) => e.status.code, 'status', 0xA700)));
    // The association is still usable afterwards.
    unawaited(_answer(peer, 1));
    expect(await assoc.sendCFind(_query).length, 1);
  });

  test('two queries at once: the second is a StateError', () async {
    final (assoc, peer) = await _associate();
    final first = assoc.sendCFind(_query).toList();
    await Future<void>.delayed(Duration.zero); // the first is now waiting
    await expectLater(assoc.sendCFind(_query).toList(), throwsStateError);
    unawaited(_answer(peer, 2));
    expect(await first, hasLength(2));
  });
}
