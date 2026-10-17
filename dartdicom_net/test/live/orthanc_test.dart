// The interop matrix against Orthanc, the test PACS (docker/compose.yaml
// by default): the five operations, plus what only a full PACS shows (its
// idle timeout, a cancelled find, a move into our StorageScp). Skipped
// unless DARTDICOM_LIVE is set; `just live` sets it. DARTDICOM_RECORD=1 also
// saves the peer's A-ASSOCIATE-AC as a test vector.
@TestOn('vm')
@Tags(['live'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:test/test.dart';

import 'support.dart';

final _env = Platform.environment;
final _host = _env['ORTHANC_HOST'] ?? 'localhost';
final _port = int.parse(_env['ORTHANC_DIMSE_PORT'] ?? '14242');
final _aet = _env['ORTHANC_AET'] ?? 'ORTHANC';
final _skip = live;

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

  test('an association left idle past the PACS\'s timeout ends clearly',
      () async {
    const ae = ApplicationEntity(
        aeTitle: 'DARTDICOM',
        requestedContexts: PresentationContexts.verification);
    final assoc = await ae.associate(_host, _port, aeTitle: _aet);
    // Orthanc's DicomScpTimeout (30 s) is shorter than our network timeout
    // (60 s), so the PACS ends it first; the DUL notices while idle.
    await Future<void>.delayed(const Duration(seconds: 35));
    await expectLater(assoc.sendCEcho(), throwsA(isA<AssociationAborted>()));
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 60)));

  test('a find cancelled on its first match leaves the association usable',
      () async {
    const ae = ApplicationEntity(aeTitle: 'DARTDICOM', requestedContexts: [
      ...PresentationContexts.verification,
      ...PresentationContexts.studyRootQueryRetrieve,
    ]);
    final assoc = await ae.associate(_host, _port, aeTitle: _aet);
    final first = await assoc
        .sendCFind(Dataset()
          ..set(DicomTags.queryRetrieveLevel, 'STUDY')
          ..setEmpty(DicomTags.studyInstanceUid))
        .first;
    expect(first.get(DicomTags.studyInstanceUid), isNotNull);
    expect(await assoc.sendCEcho(), isA<DimseSuccess>());
    await assoc.release();
  }, skip: _skip);

  test('C-STORE a fixture, then find it back', () async {
    final file = DicomFile.fromBytes(
        File('../fixtures/data/synthetic/sc_rgb.dcm').readAsBytesSync());
    final ae = ApplicationEntity(aeTitle: 'DARTDICOM', requestedContexts: [
      ...PresentationContexts.storage(
          [SopClasses.secondaryCaptureImageStorage]),
      ...PresentationContexts.studyRootQueryRetrieve,
    ]);
    final assoc = await ae.associate(_host, _port, aeTitle: _aet);
    expect(await assoc.sendCStore(file), isA<DimseSuccess>());
    final ds = file.dataset;
    final found = await assoc
        .sendCFind(Dataset()
          ..set(DicomTags.queryRetrieveLevel, 'IMAGE')
          ..set(DicomTags.studyInstanceUid,
              ds.require(DicomTags.studyInstanceUid))
          ..set(DicomTags.seriesInstanceUid,
              ds.require(DicomTags.seriesInstanceUid))
          ..set(DicomTags.sopInstanceUid, ds.require(DicomTags.sopInstanceUid)))
        .toList();
    expect(found, hasLength(1));
    await assoc.release();
  }, skip: _skip);

  test('C-MOVE a series from the PACS into our StorageScp', () async {
    const ae = ApplicationEntity(
        aeTitle: 'DARTDICOM',
        requestedContexts: PresentationContexts.studyRootQueryRetrieve);
    final assoc = await ae.associate(_host, _port, aeTitle: _aet);
    final sink = MemorySink();
    // The PACS knows DARTDICOM at this host and port (docker/compose.yaml).
    final scp = await StorageScp.start(
        aeTitle: 'DARTDICOM',
        port: int.parse(_env['DARTDICOM_SCP_PORT'] ?? '14112'),
        sink: sink,
        acceptFrom: [ScpPeer(_aet)]);
    try {
      final study = await assoc
          .sendCFind(Dataset()
            ..set(DicomTags.queryRetrieveLevel, 'STUDY')
            ..set(DicomTags.patientId, '1CT1')
            ..setEmpty(DicomTags.studyInstanceUid))
          .first;
      final series = await assoc
          .sendCFind(Dataset()
            ..set(DicomTags.queryRetrieveLevel, 'SERIES')
            ..set(DicomTags.studyInstanceUid,
                study.require(DicomTags.studyInstanceUid))
            ..setEmpty(DicomTags.seriesInstanceUid))
          .first;
      final progress = await assoc
          .sendCMove(
              Dataset()
                ..set(DicomTags.queryRetrieveLevel, 'SERIES')
                ..set(DicomTags.studyInstanceUid,
                    study.require(DicomTags.studyInstanceUid))
                ..set(DicomTags.seriesInstanceUid,
                    series.require(DicomTags.seriesInstanceUid)),
              destination: 'DARTDICOM')
          .toList();
      expect(progress.last.status, isA<DimseSuccess>());
      expect(sink.instances, hasLength(progress.last.completed));
      expect(sink.instances, isNotEmpty);
      expect(sink.instances.first.sourceAeTitle, _aet);
      expect(sink.instances.first.moveOriginatorAeTitle, 'DARTDICOM');
    } finally {
      await assoc.release();
      await scp.close();
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

  test('C-GET of a series into a DirectorySink', () async {
    const ae = ApplicationEntity(
        aeTitle: 'DARTDICOM',
        requestedContexts: PresentationContexts.studyRootQueryRetrieve,
        retrieveStorageClasses: PresentationContexts.commonStorage);
    final assoc = await ae.associate(_host, _port, aeTitle: _aet);
    final series = await assoc
        .sendCFind(Dataset()
          ..set(DicomTags.queryRetrieveLevel, 'SERIES')
          ..setEmpty(DicomTags.studyInstanceUid)
          ..setEmpty(DicomTags.seriesInstanceUid))
        .toList();
    expect(series, isNotEmpty, reason: 'seed the test PACS (just pacs-seed)');
    final root = Directory.systemTemp.createTempSync('dartdicom_live_');
    addTearDown(() => root.deleteSync(recursive: true));
    final sink = DirectorySink(root);
    final progress = await assoc
        .sendCGet(
            Dataset()
              ..set(DicomTags.queryRetrieveLevel, 'SERIES')
              ..set(DicomTags.studyInstanceUid,
                  series.first.require(DicomTags.studyInstanceUid))
              ..set(DicomTags.seriesInstanceUid,
                  series.first.require(DicomTags.seriesInstanceUid)),
            sink)
        .toList();
    await assoc.release();
    expect(progress.last.status, isA<DimseSuccess>());
    expect(progress.last.failed, 0);
    expect(sink.stored, hasLength(progress.last.completed));
    expect(sink.stored, isNotEmpty);
    final file = DicomFile.fromBytes(sink.stored.first.readAsBytesSync());
    expect(file.dataset.get(DicomTags.seriesInstanceUid),
        series.first.get(DicomTags.seriesInstanceUid));
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
