// I-12: PDUs and DIMSE messages are byte-identical to pynetdicom 3.0.4's
// encoders. Each vector in fixtures/data/net/vectors.json holds the inputs
// pynetdicom encoded and its bytes; the test builds the same thing from the
// same inputs, compares byte for byte, and round-trips the decode.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/src/dimse/fragments.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:dartdicom_net/src/pdu/items.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:test/test.dart';

typedef _Json = Map<String, Object?>;

void main() {
  final file =
      jsonDecode(File('../fixtures/data/net/vectors.json').readAsStringSync())
          as _Json;
  final vectors = (file['vectors']! as List<Object?>).cast<_Json>();

  test('the vectors come from pynetdicom 3.0.4', () {
    expect(file['pynetdicom'], '3.0.4');
  });

  group('PDUs', () {
    for (final v in vectors.where((v) => v['kind'] != 'dimse')) {
      test(v['name'], () {
        final expected = _hex(v['hex']! as String);
        final pdu = _pdu(v);
        expect(_hexOf(pdu.encode()), _hexOf(expected), reason: 'encode');
        expect(_hexOf(Pdu.decode(expected).encode()), _hexOf(expected),
            reason: 'decode, then encode');
      });
    }
  });

  group('DIMSE messages', () {
    for (final v in vectors.where((v) => v['kind'] == 'dimse')) {
      final ctx = v['context']! as int;
      final maxPdu = v['max_pdu']! as int;
      test('${v['name']} (context $ctx, max PDU $maxPdu)', () {
        final command = _command((v['command']! as List<Object?>).cast());
        final dataset = v['dataset'] as String?;
        final message =
            DimseMessage(ctx, command, dataset == null ? null : _hex(dataset));
        expect(
            [for (final pdu in fragment(message, maxPdu)) _hexOf(pdu.encode())],
            v['pdus']);
      });
    }

    // The request builders the association uses produce pynetdicom's command
    // sets (the generic builds above check the encoding).
    test('requestCommand builds C-ECHO, C-FIND and C-GET requests', () {
      for (final (name, field, sopClass, hasDataset) in [
        ('C-ECHO-RQ', CommandField.cEchoRq, SopClasses.verification, false),
        (
          'C-FIND-RQ',
          CommandField.cFindRq,
          SopClasses.studyRootQueryRetrieveInformationModelFind,
          true
        ),
        (
          'C-GET-RQ',
          CommandField.cGetRq,
          SopClasses.studyRootQueryRetrieveInformationModelGet,
          true
        ),
      ]) {
        final v = vectors.firstWhere((v) => v['name'] == name);
        final expected = _command((v['command']! as List<Object?>).cast());
        final built = requestCommand(
            field, expected.require(DicomTags.messageId), sopClass,
            hasDataset: hasDataset,
            priority: hasDataset ? mediumPriority : null);
        expect(_hexOf(DimseMessage(1, built).encodeCommand()),
            _hexOf(DimseMessage(1, expected).encodeCommand()),
            reason: name);
      }
    });

    test('a C-MOVE request is requestCommand plus Move Destination', () {
      final v = vectors.firstWhere((v) => v['name'] == 'C-MOVE-RQ');
      final expected = _command((v['command']! as List<Object?>).cast());
      final built = requestCommand(
          CommandField.cMoveRq,
          expected.require(DicomTags.messageId),
          SopClasses.studyRootQueryRetrieveInformationModelMove,
          hasDataset: true,
          priority: mediumPriority)
        ..set(DicomTags.moveDestination, 'DARTDICOM');
      expect(_hexOf(DimseMessage(1, built).encodeCommand()),
          _hexOf(DimseMessage(1, expected).encodeCommand()));
    });

    test('storeCommand builds C-STORE-RQ, with and without a move originator',
        () {
      final stores = vectors.where((v) => v['name'] == 'C-STORE-RQ');
      expect(stores, hasLength(3));
      for (final v in stores) {
        final expected = _command((v['command']! as List<Object?>).cast());
        final built = storeCommand(
            expected.require(DicomTags.messageId),
            expected.require(DicomTags.affectedSopClassUid),
            expected.require(DicomTags.affectedSopInstanceUid),
            moveOriginatorAeTitle:
                expected.get(DicomTags.moveOriginatorApplicationEntityTitle),
            moveOriginatorMessageId:
                expected.get(DicomTags.moveOriginatorMessageId));
        expect(_hexOf(DimseMessage(1, built).encodeCommand()),
            _hexOf(DimseMessage(1, expected).encodeCommand()));
      }
    });

    test('cancelCommand builds C-CANCEL-RQ', () {
      final v = vectors.firstWhere((v) => v['name'] == 'C-CANCEL-RQ');
      final expected = _command((v['command']! as List<Object?>).cast());
      final built =
          cancelCommand(expected.require(DicomTags.messageIdBeingRespondedTo));
      expect(_hexOf(DimseMessage(1, built).encodeCommand()),
          _hexOf(DimseMessage(1, expected).encodeCommand()));
    });
  });
}

Pdu _pdu(_Json v) => switch (v['kind']) {
      'associate_rq' => AssociateRq(
          calledAeTitle: v['called']! as String,
          callingAeTitle: v['calling']! as String,
          contexts: [
            for (final c in (v['contexts']! as List<Object?>).cast<_Json>())
              ProposedContext(c['id']! as int, c['abstract_syntax']! as String,
                  (c['transfer_syntaxes']! as List<Object?>).cast()),
          ],
          userInformation: _user(v['user']! as _Json),
        ),
      'associate_ac' => AssociateAc(
          calledAeTitle: v['called']! as String,
          callingAeTitle: v['calling']! as String,
          results: [
            for (final r in (v['results']! as List<Object?>).cast<_Json>())
              ContextResult(r['id']! as int, r['result']! as int,
                  r['transfer_syntax']! as String),
          ],
          userInformation: _user(v['user']! as _Json),
        ),
      'associate_rj' => AssociateRj(
          result: v['result']! as int,
          source: v['source']! as int,
          reason: v['reason']! as int),
      'p_data_tf' => PDataTf([
          for (final p in (v['pdvs']! as List<Object?>).cast<_Json>())
            Pdv(p['context']! as int, _hex(p['data']! as String),
                isCommand: p['command']! as bool, isLast: p['last']! as bool),
        ]),
      'release_rq' => const ReleaseRq(),
      'release_rp' => const ReleaseRp(),
      'abort' =>
        Abort(source: v['source']! as int, reason: v['reason']! as int),
      final kind => throw StateError('unknown vector kind $kind'),
    };

UserInformation _user(_Json u) => UserInformation(
      maxLength: u['max_length']! as int,
      implementationClassUid: u['class_uid']! as String,
      implementationVersionName: u['version'] as String?,
      roles: [
        for (final r in (u['roles'] as List<Object?>? ?? []).cast<_Json>())
          RoleSelection(r['sop_class']! as String,
              scu: r['scu']! as bool, scp: r['scp']! as bool),
      ],
      asyncWindow: switch (u['async']) {
        [final int invoked, final int performed] =>
          AsyncOperationsWindow(invoked: invoked, performed: performed),
        _ => null,
      },
    );

/// A command set built from pynetdicom's elements (tag, VR, value).
Dataset _command(List<_Json> elements) {
  final ds = Dataset();
  for (final e in elements) {
    final vr = Vr.fromCode(e['vr']! as String)!;
    final value = e['value'];
    ds.setRaw(Tag(int.parse(e['tag']! as String, radix: 16)), vr,
        value is int ? [value] : [value! as String]);
  }
  return ds;
}

Uint8List _hex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

String _hexOf(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
