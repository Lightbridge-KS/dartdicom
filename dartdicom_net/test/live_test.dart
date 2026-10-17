// Live gate: the real thing against a test PACS (docker/compose.yaml by
// default). Skipped unless DARTDICOM_LIVE is set; `just live` sets it.
// DARTDICOM_RECORD=1 also saves the peer's A-ASSOCIATE-AC as a test vector.
@TestOn('vm')
@Tags(['live'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:test/test.dart';

final _env = Platform.environment;
final _host = _env['ORTHANC_HOST'] ?? 'localhost';
final _port = int.parse(_env['ORTHANC_DIMSE_PORT'] ?? '14242');
final _aet = _env['ORTHANC_AET'] ?? 'ORTHANC';
final _skip = _env.containsKey('DARTDICOM_LIVE')
    ? false
    : 'set DARTDICOM_LIVE=1 (just live) with a test PACS running';

void main() {
  test('C-ECHO, then release', () async {
    const ae = ApplicationEntity(
        aeTitle: 'DARTDICOM',
        requestedContexts: PresentationContexts.verification);
    final socket = await SocketTransport.connect(_host, _port);
    final recording = _Recording(socket);
    final assoc = await ae.associateOver(recording, aeTitle: _aet);
    expect(assoc.acceptedContexts, hasLength(1));
    expect(await assoc.sendCEcho(), isA<DimseSuccess>());
    await assoc.release();
    if (_env.containsKey('DARTDICOM_RECORD')) {
      File('test/vectors/orthanc_associate_ac.bin')
          .writeAsBytesSync(recording.firstPdu());
    }
  }, skip: _skip);

  test('C-FIND at STUDY, then SERIES level', () async {
    const ae = ApplicationEntity(
        aeTitle: 'DARTDICOM',
        requestedContexts: PresentationContexts.studyRootQueryRetrieve);
    final assoc = await ae.associate(_host, _port, aeTitle: _aet);
    final studies = await assoc
        .sendCFind(Dataset()
          ..set(DicomTags.queryRetrieveLevel, 'STUDY')
          ..setEmpty(DicomTags.studyInstanceUid)
          ..setEmpty(DicomTags.patientId))
        .toList();
    expect(studies, isNotEmpty, reason: 'seed the test PACS (just pacs-seed)');
    final study = studies.first.require(DicomTags.studyInstanceUid);
    final series = await assoc
        .sendCFind(Dataset()
          ..set(DicomTags.queryRetrieveLevel, 'SERIES')
          ..set(DicomTags.studyInstanceUid, study)
          ..setEmpty(DicomTags.seriesInstanceUid)
          ..setEmpty(DicomTags.modality))
        .toList();
    expect(series, isNotEmpty);
    expect(series.first.get(DicomTags.seriesInstanceUid), isNotNull);
    await assoc.release();
  }, skip: _skip);
}

/// Passes everything through and keeps the bytes received.
final class _Recording implements Transport {
  _Recording(this._inner);

  final Transport _inner;
  final _received = BytesBuilder();

  Uint8List firstPdu() {
    final bytes = _received.toBytes();
    final length = ByteData.sublistView(bytes, 2, 6).getUint32(0);
    return Uint8List.sublistView(bytes, 0, 6 + length);
  }

  @override
  Stream<Uint8List> get incoming =>
      _inner.incoming.map((chunk) => (_received..add(chunk), chunk).$2);

  @override
  Future<void> send(Uint8List bytes) => _inner.send(bytes);

  @override
  Future<void> close() => _inner.close();
}
