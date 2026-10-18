// C-STORE as SCU (PRD N-10): which presentation context a file goes out on,
// how it is encoded, the refusals that name the fix, and the roles.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/io.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:dartdicom_net/src/pdu/items.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:test/test.dart';

import '../support/peer.dart';

DicomFile _fixture(String path) =>
    DicomFile.fromBytes(File('../fixtures/data/$path').readAsBytesSync());

const _ct = SopClasses.ctImageStorage;

/// Associates [ae] with a peer accepting every context with its first
/// syntax; [roles] overrides the role reply.
Future<(Association, ScriptedPeer)> _associate(ApplicationEntity ae,
    {List<RoleSelection>? roles}) async {
  final (transport, peer) = ScriptedPeer.connect();
  unawaited(() async {
    final rq = peer.request = await peer.next() as AssociateRq;
    await peer.send(AssociateAc(
      calledAeTitle: rq.calledAeTitle,
      callingAeTitle: rq.callingAeTitle,
      results: [
        for (final c in rq.contexts)
          ContextResult(c.id, 0, c.transferSyntaxes.first),
      ],
      userInformation: UserInformation(
          maxLength: 16384,
          implementationClassUid: '1.2.3.4',
          roles: roles ?? rq.userInformation.roles),
    ));
  }());
  return (await ae.associateOver(transport, aeTitle: 'PEER'), peer);
}

/// Answers one C-STORE-RQ with [status]; returns it and the syntax its
/// context was accepted in.
Future<(DimseMessage, Uid)> _answer(ScriptedPeer peer,
    {int status = 0x0000}) async {
  final rq = await peer.nextMessage();
  expect(rq.commandField, CommandField.cStoreRq);
  final rsp = ScriptedPeer.response(CommandField.cStoreRsp, rq, status)
    ..set(DicomTags.affectedSopInstanceUid, rq.affectedSopInstanceUid!);
  await peer.sendMessage(DimseMessage(rq.contextId, rsp));
  final ts = peer.request!.contexts
      .firstWhere((c) => c.id == rq.contextId)
      .transferSyntaxes
      .first;
  return (rq, Uid(ts));
}

ApplicationEntity _ae(List<PresentationContext> contexts,
        {List<Uid> retrieve = const [], DeflateCodec? codec}) =>
    ApplicationEntity(
        aeTitle: 'DARTDICOM',
        requestedContexts: contexts,
        retrieveStorageClasses: retrieve,
        deflateCodec: codec);

void main() {
  test('an untouched file goes out byte for byte in its own syntax', () async {
    final file = _fixture('synthetic/ct_signed_explicit_le.dcm');
    final (assoc, peer) =
        await _associate(_ae(PresentationContexts.storage([_ct])));
    final answer = _answer(peer);
    expect(await assoc.sendCStore(file), isA<DimseSuccess>());
    final (rq, ts) = await answer;
    expect(ts, TransferSyntaxes.explicitVrLittleEndian);
    final raw = File('../fixtures/data/synthetic/ct_signed_explicit_le.dcm')
        .readAsBytesSync();
    final int groupLength =
        file.meta.dataset.require(DicomTags.fileMetaInformationGroupLength);
    final metaEnd = 144 + groupLength;
    expect(rq.dataset, raw.sublist(metaEnd));
    expect(rq.affectedSopInstanceUid,
        file.dataset.require(DicomTags.sopInstanceUid));
    expect(rq.command.get(DicomTags.priority), 0);
  });

  test('a native file is re-encoded when its own syntax was not accepted',
      () async {
    final file = _fixture('synthetic/ct_implicit_le.dcm');
    final (assoc, peer) = await _associate(_ae(PresentationContexts.storage(
        [_ct],
        transferSyntaxes: [TransferSyntaxes.explicitVrLittleEndian])));
    final answer = _answer(peer);
    await assoc.sendCStore(file);
    final (rq, ts) = await answer;
    expect(ts, TransferSyntaxes.explicitVrLittleEndian);
    final sent = Dataset.fromBytes(rq.dataset!, transferSyntax: ts);
    expect(sent.get(DicomTags.rows), file.dataset.get(DicomTags.rows));
    expect(sent.require(DicomTags.pixelData),
        file.dataset.require(DicomTags.pixelData));
  });

  test('Big Endian goes out as Little Endian, which the core can write',
      () async {
    final file = _fixture('synthetic/ct_explicit_be.dcm');
    final (assoc, peer) = await _associate(_ae([
      const PresentationContext(_ct,
          transferSyntaxes: [TransferSyntaxes.explicitVrBigEndian]),
      const PresentationContext(_ct),
    ]));
    final answer = _answer(peer);
    await assoc.sendCStore(file);
    expect((await answer).$2, TransferSyntaxes.explicitVrLittleEndian);
  });

  test('Deflated goes out deflated only with a codec', () async {
    final file = _fixture('synthetic/ct_deflated.dcm');
    final contexts = [
      const PresentationContext(_ct,
          transferSyntaxes: [TransferSyntaxes.deflatedExplicitVrLittleEndian]),
      const PresentationContext(_ct),
    ];
    for (final (codec, expected) in [
      (null, TransferSyntaxes.explicitVrLittleEndian),
      (
        const ZLibDeflateCodec(),
        TransferSyntaxes.deflatedExplicitVrLittleEndian
      ),
    ]) {
      final (assoc, peer) = await _associate(_ae(contexts, codec: codec));
      final answer = _answer(peer);
      await assoc.sendCStore(file);
      expect((await answer).$2, expected);
    }
  });

  test('an encapsulated file needs a context in its own syntax', () async {
    final file = _fixture('pydicom/SC_rgb_rle.dcm');
    final (assoc, _) = await _associate(_ae(PresentationContexts.storage(
        [SopClasses.secondaryCaptureImageStorage])));
    expect(
        () => assoc.sendCStore(file),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('transferSyntaxes: [1.2.840.10008.1.2.5]'))));
  });

  test('no context for the class is a StateError naming the fix', () async {
    final (assoc, _) = await _associate(_ae(PresentationContexts.verification));
    expect(
        () => assoc.sendCStore(_fixture('synthetic/ct_signed_explicit_le.dcm')),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('PresentationContexts.storage'))));
  });

  test('a failure status is a value (D3)', () async {
    final (assoc, peer) =
        await _associate(_ae(PresentationContexts.storage([_ct])));
    unawaited(_answer(peer, status: 0xA700));
    final status =
        await assoc.sendCStore(_fixture('synthetic/ct_signed_explicit_le.dcm'));
    expect(status, isA<DimseFailure>().having((s) => s.code, 'code', 0xA700));
  });

  group('roles', () {
    test('a class both sent and retrieved is proposed with both roles',
        () async {
      final (assoc, peer) = await _associate(
          _ae(PresentationContexts.storage([_ct]), retrieve: [_ct]));
      final role = peer.request!.userInformation.roles.single;
      expect((role.scu, role.scp), (true, true));
      unawaited(_answer(peer));
      expect(
          await assoc
              .sendCStore(_fixture('synthetic/ct_signed_explicit_le.dcm')),
          isA<DimseSuccess>());
    });

    test('a retrieve-only class is proposed as SCP only', () async {
      final (_, peer) = await _associate(_ae(const [], retrieve: [_ct]));
      final role = peer.request!.userInformation.roles.single;
      expect((role.scu, role.scp), (false, true));
    });

    test('without the SCU role, no context is usable', () async {
      final (assoc, _) = await _associate(
          _ae(PresentationContexts.storage([_ct]), retrieve: [_ct]),
          roles: [RoleSelection(_ct.value, scu: false, scp: true)]);
      expect(
          () =>
              assoc.sendCStore(_fixture('synthetic/ct_signed_explicit_le.dcm')),
          throwsStateError);
    });
  });
}
