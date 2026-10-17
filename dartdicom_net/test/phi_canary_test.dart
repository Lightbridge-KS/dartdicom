// The PHI canary over the protocol (I-9, blueprint F5): the phi_canary
// fixture carries a marker (ZXQV) in names, IDs, descriptions, a private
// element and nested sequence text. Sent through a find, a get, a store
// and a StorageScp association, traced at hex level, it must not reach a
// trace line or an exception unless showValues is set.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:test/test.dart';

import 'support/peer.dart';

final _file = DicomFile.fromBytes(
    File('../fixtures/data/synthetic/phi_canary.dcm').readAsBytesSync());
final _dataset = _file.dataset;
final _bytes =
    _dataset.toBytes(transferSyntax: TransferSyntaxes.explicitVrLittleEndian);
final _instanceUid = _dataset.require(DicomTags.sopInstanceUid);
const _sc = SopClasses.secondaryCaptureImageStorage;

final _marker = RegExp('zxqv', caseSensitive: false);

/// The marker as the trace prints bytes.
const _markerHex = '5a 58 51 56';

/// Every trace line of the four exchanges, at hex level.
Future<List<String>> _traceAll({required bool showValues}) async {
  final lines = <String>[];
  final trace = Trace(TraceSink.lines(lines.add),
      level: TraceLevel.hex, showValues: showValues);
  final ae = ApplicationEntity(
      aeTitle: 'SCU',
      requestedContexts: [
        ...PresentationContexts.studyRootQueryRetrieve,
        ...PresentationContexts.storage([_sc]),
      ],
      retrieveStorageClasses: const [_sc],
      trace: trace);

  // A find whose match is the canary, a get that stores it, and a store.
  final (transport, peer) = ScriptedPeer.connect();
  unawaited(peer.accept());
  final assoc = await ae.associateOver(transport, aeTitle: 'PEER');
  final peerSide = () async {
    final find = await peer.nextMessage();
    await peer.sendMessage(DimseMessage(
        find.contextId,
        ScriptedPeer.response(CommandField.cFindRsp, find, 0xFF00,
            hasDataset: true),
        _bytes));
    await peer.sendMessage(DimseMessage(find.contextId,
        ScriptedPeer.response(CommandField.cFindRsp, find, 0x0000)));
    final get = await peer.nextMessage();
    final storeContext = peer.request!.contexts
        .lastWhere((c) => c.abstractSyntax == _sc.value)
        .id;
    await peer.sendMessage(DimseMessage(
        storeContext, storeCommand(9, _sc.value, _instanceUid), _bytes));
    await peer.nextMessage();
    await peer.sendMessage(DimseMessage(
        get.contextId,
        ScriptedPeer.response(CommandField.cGetRsp, get, 0x0000)
          ..set(DicomTags.numberOfCompletedSuboperations, 1)));
    final store = await peer.nextMessage();
    await peer.sendMessage(DimseMessage(
        store.contextId,
        ScriptedPeer.response(CommandField.cStoreRsp, store, 0x0000)
          ..set(DicomTags.affectedSopInstanceUid, _instanceUid)));
    await peer.acceptRelease();
  }();
  final query = Dataset()
    ..set(DicomTags.queryRetrieveLevel, 'STUDY')
    ..set(DicomTags.patientName, 'ZXQV*');
  expect(await assoc.sendCFind(query).length, 1);
  await assoc
      .sendCGet(
          Dataset()
            ..set(DicomTags.queryRetrieveLevel, 'IMAGE')
            ..set(DicomTags.sopInstanceUid, _instanceUid),
          MemorySink())
      .drain<void>();
  expect(await assoc.sendCStore(_file), isA<DimseSuccess>());
  await assoc.release();
  await peerSide;

  // A StorageScp association, both sides traced.
  final scp = await StorageScp.start(
      aeTitle: 'DARTDICOM',
      sink: MemorySink(),
      acceptFrom: const [ScpPeer('SCU')],
      address: InternetAddress.loopbackIPv4,
      trace: trace);
  final toScp = await ae.associate('127.0.0.1', scp.port, aeTitle: 'DARTDICOM');
  expect(await toScp.sendCStore(_file), isA<DimseSuccess>());
  await toScp.release();
  await scp.close();
  return lines;
}

void main() {
  test('the canary carries the marker in the bytes sent', () {
    expect(String.fromCharCodes(_bytes), contains('ZXQV'));
  });

  test('no trace line shows a value (hex level, showValues off)', () async {
    final lines = await _traceAll(showValues: false);
    expect(lines.where((l) => l.contains('DIMSE')), isNotEmpty);
    expect(lines.where((l) => l.contains('P-DATA-TF')), isNotEmpty);
    for (final line in lines) {
      expect(line, isNot(matches(_marker)), reason: line);
      expect(line, isNot(contains(_markerHex)), reason: line);
      expect(line, isNot(contains(_instanceUid)), reason: line);
    }
  });

  test('showValues opts in: the bytes and the UIDs appear', () async {
    final lines = await _traceAll(showValues: true);
    expect(lines, contains(contains(_markerHex)));
    expect(lines, contains(contains(_instanceUid)));
  });

  test('no exception shows a value', () async {
    // A failed find, a protocol violation, and a rejected store: each
    // carries the canary on the wire.
    final messages = <String>[];
    final (transport, peer) = ScriptedPeer.connect();
    unawaited(peer.accept());
    final assoc = await ApplicationEntity(aeTitle: 'SCU', requestedContexts: [
      ...PresentationContexts.verification,
      ...PresentationContexts.studyRootQueryRetrieve,
    ]).associateOver(transport, aeTitle: 'PEER');
    final peerSide = () async {
      final find = await peer.nextMessage();
      await peer.sendMessage(DimseMessage(
          find.contextId,
          ScriptedPeer.response(CommandField.cFindRsp, find, 0xA700,
              hasDataset: true),
          _bytes));
      final echo = await peer.nextMessage();
      // A response to the wrong request, with the canary attached.
      await peer.sendMessage(DimseMessage(
          echo.contextId,
          ScriptedPeer.response(CommandField.cFindRsp, find, 0xFF00,
              hasDataset: true),
          _bytes));
    }();
    try {
      await assoc
          .sendCFind(Dataset()..set(DicomTags.patientName, 'ZXQV^Q'))
          .drain<void>();
    } on DimseException catch (e) {
      messages.add('$e');
    }
    try {
      await assoc.sendCEcho();
    } on DimseException catch (e) {
      messages.add('$e');
    }
    await peerSide;
    // A store the peer can't take (no context for the class).
    try {
      await assoc.sendCStore(_file);
    } on Object catch (e) {
      messages.add('$e');
    }
    expect(messages, hasLength(3));
    for (final m in messages) {
      expect(m, isNot(matches(_marker)), reason: m);
      expect(m, isNot(contains(_instanceUid)), reason: m);
    }
  });
}
