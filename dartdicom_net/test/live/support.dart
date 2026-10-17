// What the live interop tests share (M3 decision 2): the peers, how to
// skip a peer that isn't running, and the five operations run against any
// peer the same way.
import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:test/test.dart';

final env = Platform.environment;

/// Why every live test skips: no test PACS was asked for.
final String? live = env.containsKey('DARTDICOM_LIVE')
    ? null
    : 'set DARTDICOM_LIVE=1 (just live) with a test PACS running';

/// Why a test needing the peer behind [variable] skips: it isn't running
/// (`scripts/interop_peers.sh` starts the peers). In CI it is required.
String? needs(String variable, String peer) {
  if (live != null) return live;
  if (env.containsKey(variable)) return null;
  if (env.containsKey('CI')) {
    throw StateError('$peer is required in CI, and $variable is unset');
  }
  return '$peer is not running (scripts/interop_peers.sh starts it)';
}

/// This app's AE title, and the port its StorageScp takes as a C-MOVE
/// destination (the peers are configured for both).
const ourAeTitle = 'DARTDICOM';
final scpPort = int.parse(env['DARTDICOM_SCP_PORT'] ?? '14112');

/// A peer to associate with.
typedef Peer = ({String host, int port, String aeTitle});

/// A peer from the port in [variable], titled [aeTitle], on this host.
Peer peerAt(String variable, String aeTitle) =>
    (host: '127.0.0.1', port: int.parse(env[variable]!), aeTitle: aeTitle);

/// The patient of `CT_small.dcm`, which every peer is seeded with.
const patientId = '1CT1';

const _ae = ApplicationEntity(
  aeTitle: ourAeTitle,
  requestedContexts: [
    ...PresentationContexts.verification,
    ...PresentationContexts.studyRootQueryRetrieve,
  ],
  retrieveStorageClasses: PresentationContexts.commonStorage,
);

Future<Association> associate(Peer peer, {ApplicationEntity ae = _ae}) =>
    ae.associate(peer.host, peer.port, aeTitle: peer.aeTitle);

Future<void> expectEcho(Peer peer) async {
  final assoc = await associate(peer);
  expect(await assoc.sendCEcho(), isA<DimseSuccess>());
  await assoc.release();
}

/// Stores [file] on [peer], expecting success.
Future<void> expectStore(Peer peer, String file) async {
  final dicom = DicomFile.fromBytes(File(file).readAsBytesSync());
  final assoc = await associate(peer,
      ae: ApplicationEntity(
          aeTitle: ourAeTitle,
          requestedContexts: PresentationContexts.storage(
              [Uid(dicom.dataset.require(DicomTags.sopClassUid))])));
  expect(await assoc.sendCStore(dicom), isA<DimseSuccess>());
  await assoc.release();
}

/// The study of [patientId] on [peer] and its first series, by C-FIND.
Future<(String, String)> findSeries(Association assoc) async {
  final studies = await assoc
      .sendCFind(Dataset()
        ..set(DicomTags.queryRetrieveLevel, 'STUDY')
        ..set(DicomTags.patientId, patientId)
        ..setEmpty(DicomTags.studyInstanceUid))
      .toList();
  expect(studies, hasLength(1), reason: 'the peer holds one $patientId study');
  final study = studies.single.require(DicomTags.studyInstanceUid);
  final series = await assoc
      .sendCFind(Dataset()
        ..set(DicomTags.queryRetrieveLevel, 'SERIES')
        ..set(DicomTags.studyInstanceUid, study)
        ..setEmpty(DicomTags.seriesInstanceUid))
      .toList();
  expect(series, isNotEmpty);
  return (study, series.first.require(DicomTags.seriesInstanceUid));
}

/// A SERIES-level retrieve identifier: unique keys only, which every peer
/// takes (pynetdicom's qrscp takes nothing else).
Dataset seriesQuery(String study, String series) => Dataset()
  ..set(DicomTags.queryRetrieveLevel, 'SERIES')
  ..set(DicomTags.studyInstanceUid, study)
  ..set(DicomTags.seriesInstanceUid, series);

Future<void> expectFind(Peer peer) async {
  final assoc = await associate(peer);
  await findSeries(assoc);
  await assoc.release();
}

Future<void> expectGet(Peer peer) async {
  final assoc = await associate(peer);
  final (study, series) = await findSeries(assoc);
  final sink = MemorySink();
  final progress =
      await assoc.sendCGet(seriesQuery(study, series), sink).toList();
  await assoc.release();
  expect(progress.last.status, isA<DimseSuccess>());
  expect(sink.instances, isNotEmpty);
  expect(sink.instances, hasLength(progress.last.completed));
  expect(sink.instances.first.sourceAeTitle, peer.aeTitle);
}

/// C-MOVE of [patientId]'s first series into our StorageScp, which accepts
/// [mover], the AE title the peer stores with.
Future<void> expectMove(Peer peer, {required String mover}) async {
  final sink = MemorySink();
  final scp = await StorageScp.start(
      aeTitle: ourAeTitle,
      port: scpPort,
      sink: sink,
      acceptFrom: [ScpPeer(mover)]);
  try {
    final assoc = await associate(peer);
    final (study, series) = await findSeries(assoc);
    final progress = await assoc
        .sendCMove(seriesQuery(study, series), destination: ourAeTitle)
        .toList();
    await assoc.release();
    expect(progress.last.status, isA<DimseSuccess>());
    expect(sink.instances, isNotEmpty);
    expect(sink.instances, hasLength(progress.last.completed));
    expect(sink.instances.first.sourceAeTitle, mover);
  } finally {
    await scp.close();
  }
}

/// Runs [command] (an SCU of another toolkit) against a StorageScp that
/// accepts [callingAeTitle], and returns what it stored.
Future<List<ReceivedInstance>> storedBy(String callingAeTitle,
    Future<ProcessResult> Function(int port) command) async {
  final sink = MemorySink();
  final scp = await StorageScp.start(
      aeTitle: ourAeTitle,
      sink: sink,
      acceptFrom: [ScpPeer(callingAeTitle)],
      address: InternetAddress.loopbackIPv4);
  try {
    final result = await command(scp.port);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  } finally {
    await scp.close();
  }
  return sink.instances;
}

/// The files a store SCP of another toolkit wrote into [dir].
List<File> filesIn(String dir) =>
    Directory(dir).listSync(recursive: true).whereType<File>().toList();
