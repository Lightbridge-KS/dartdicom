// The protocol trace (PRD N-14): what each level shows over a scripted
// C-GET with one C-STORE sub-operation, and that it shows no value unless
// asked (I-9, blueprint F5).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:test/test.dart';

import '../support/peer.dart';

final _instance = DicomFile.fromBytes(
        File('../fixtures/data/synthetic/ct_signed_explicit_le.dcm')
            .readAsBytesSync())
    .dataset;
final _instanceUid = _instance.require(DicomTags.sopInstanceUid);

/// The trace of one C-GET of one instance, then a release.
Future<List<String>> _traceGet(TraceLevel level,
    {bool showValues = false, TraceSink? sink}) async {
  final lines = <String>[];
  final ae = ApplicationEntity(
    aeTitle: 'DARTDICOM',
    requestedContexts: PresentationContexts.studyRootQueryRetrieve,
    retrieveStorageClasses: const [SopClasses.ctImageStorage],
    trace: Trace(sink ?? TraceSink.lines(lines.add),
        level: level, showValues: showValues),
  );
  final (transport, peer) = ScriptedPeer.connect();
  unawaited(peer.accept());
  final assoc = await ae.associateOver(transport, aeTitle: 'PEER');
  final peerSide = () async {
    final rq = await peer.nextMessage();
    await peer.sendMessage(DimseMessage(
        peer.contextFor(SopClasses.ctImageStorage),
        Dataset()
          ..set(DicomTags.affectedSopClassUid, SopClasses.ctImageStorage.value)
          ..set(DicomTags.commandField, CommandField.cStoreRq)
          ..set(DicomTags.messageId, 7)
          ..set(DicomTags.priority, 0)
          ..set(DicomTags.commandDataSetType, 0x0001)
          ..set(DicomTags.affectedSopInstanceUid, _instanceUid),
        _instance.toBytes(
            transferSyntax: TransferSyntaxes.explicitVrLittleEndian)));
    await peer.nextMessage(); // our C-STORE-RSP
    await peer.sendMessage(DimseMessage(
        rq.contextId,
        ScriptedPeer.response(CommandField.cGetRsp, rq, 0x0000)
          ..set(DicomTags.numberOfCompletedSuboperations, 1)
          ..set(DicomTags.numberOfFailedSuboperations, 0)
          ..set(DicomTags.numberOfWarningSuboperations, 0)));
    await peer.acceptRelease();
  }();
  await assoc
      .sendCGet(
          Dataset()
            ..set(DicomTags.queryRetrieveLevel, 'IMAGE')
            ..set(DicomTags.sopInstanceUid, '1.2.3'),
          MemorySink())
      .drain<void>();
  await assoc.release();
  await peerSide;
  return lines;
}

void main() {
  test('DIMSE: each message by name, IDs and counts, no PDUs', () async {
    final lines = await _traceGet(TraceLevel.dimse);
    expect(lines, everyElement(contains('DIMSE')));
    expect(lines.first, startsWith('→ DIMSE C-GET-RQ ctx 3'));
    expect(lines, contains(startsWith('← DIMSE C-STORE-RQ')));
    expect(lines, contains(startsWith('→ DIMSE C-STORE-RSP')));
    expect(
        lines.last,
        allOf(contains('C-GET-RSP'),
            contains('NumberOfCompletedSuboperations 1')));
    expect(lines.firstWhere((l) => l.contains('C-STORE-RQ')),
        allOf(contains('AffectedSOPInstanceUID ***'), contains('dataset ')));
  });

  test('PDU: each PDU with its transition, and no bytes', () async {
    final lines = await _traceGet(TraceLevel.pdu);
    expect(
        lines, contains(startsWith('→ PDU A-ASSOCIATE-RQ DARTDICOM → PEER')));
    expect(lines, contains(contains('Sta5 + Evt3 → AE-3 → Sta6')));
    expect(lines, contains(contains('Sta6 + Evt9 → DT-1 → Sta6')));
    expect(lines, contains(contains('Sta7 + Evt13 → AR-3 → Sta1')));
    expect(lines.where((l) => l.contains(' 01 00 00 00')), isEmpty);
  });

  test('hex: the association PDUs\' bytes, never P-DATA\'s', () async {
    final lines = await _traceGet(TraceLevel.hex);
    expect(lines.firstWhere((l) => l.contains('A-ASSOCIATE-RQ')),
        contains('| 01 00 00 00'));
    final pData = lines.where((l) => l.contains('P-DATA-TF'));
    expect(pData, isNotEmpty);
    expect(pData,
        everyElement(isNot(matches(RegExp(r'\| [0-9a-f]{2} [0-9a-f]{2}')))));
  });

  test('no value appears unless showValues is set', () async {
    final quiet = await _traceGet(TraceLevel.hex);
    expect(quiet, everyElement(isNot(contains(_instanceUid))));
    final loud = await _traceGet(TraceLevel.hex, showValues: true);
    expect(loud, contains(contains('AffectedSOPInstanceUID $_instanceUid')));
    expect(loud.where((l) => l.contains('P-DATA-TF')),
        contains(matches(RegExp(r'\| 0[0-9a-f] '))));
  });

  test('a sink that throws never disturbs the association', () async {
    final lines = await _traceGet(TraceLevel.hex, sink: _Throwing());
    expect(lines, isEmpty);
  });
}

final class _Throwing implements TraceSink {
  @override
  void record(TraceEvent event) => throw StateError('broken sink');
}
