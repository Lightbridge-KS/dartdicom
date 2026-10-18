// The tracer bullet, end to end: find a study on a PACS, retrieve one of
// its series into a directory, read a stored file, and render its first
// frame as an 8-bit PGM image.
//
//   dart run bin/retrieve_and_render.dart [--patient-id=ID] [--out=DIR]
//       [--host=localhost] [--port=14242] [--called-ae=ORTHANC]
//       [--calling-ae=DARTDICOM] [--via=get|move] [--scp-port=14112]
//
// --via=get (the default) retrieves over this association with C-GET: no
// inbound port. --via=move asks the PACS to send the series to this app's
// StorageScp with C-MOVE: the PACS must know the calling AE title, this
// host and the SCP port, and a firewall must let it in.
//
// Defaults match docker/compose.yaml (`just pacs-up`, `just pacs-seed`).
// It prints counts, UIDs and progress, never patient attributes.
import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/io.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';

Future<void> main(List<String> args) async {
  final options = {
    'host': Platform.environment['ORTHANC_HOST'] ?? 'localhost',
    'port': Platform.environment['ORTHANC_DIMSE_PORT'] ?? '14242',
    'called-ae': Platform.environment['ORTHANC_AET'] ?? 'ORTHANC',
    'calling-ae': 'DARTDICOM',
    'out': 'build/retrieve_and_render',
    'via': 'get',
    'scp-port': Platform.environment['DARTDICOM_SCP_PORT'] ?? '14112',
    for (final arg in args)
      if (RegExp(r'^--([\w-]+)=(.*)$').firstMatch(arg) case final m?)
        m.group(1)!: m.group(2)!,
  };
  final out = Directory(options['out']!);

  final ae = ApplicationEntity(
    aeTitle: options['calling-ae']!,
    requestedContexts: [
      ...PresentationContexts.verification,
      ...PresentationContexts.studyRootQueryRetrieve,
    ],
    retrieveStorageClasses: PresentationContexts.commonStorage,
  );
  final assoc = await ae.associate(
      options['host']!, int.parse(options['port']!),
      aeTitle: options['called-ae']!);
  final sink = DirectorySink(Directory('${out.path}/instances'));
  try {
    stdout.writeln('C-ECHO: ${await assoc.sendCEcho()}');

    // Query: an empty element is a return key (surface S3).
    final studyQuery = Dataset()
      ..set(DicomTags.queryRetrieveLevel, 'STUDY')
      ..setEmpty(DicomTags.studyInstanceUid);
    final patientId = options['patient-id'];
    if (patientId != null) studyQuery.set(DicomTags.patientId, patientId);
    final studies = await assoc.sendCFind(studyQuery).toList();
    stdout.writeln('C-FIND STUDY: ${studies.length} match(es)');
    if (studies.isEmpty) {
      throw StateError('no study matched; seed the PACS with `just pacs-seed`');
    }
    final studyUid = studies.first.require(DicomTags.studyInstanceUid);

    final series = await assoc
        .sendCFind(Dataset()
          ..set(DicomTags.queryRetrieveLevel, 'SERIES')
          ..set(DicomTags.studyInstanceUid, studyUid)
          ..setEmpty(DicomTags.seriesInstanceUid)
          ..setEmpty(DicomTags.modality))
        .toList();
    final seriesUid = series.first.require(DicomTags.seriesInstanceUid);
    stdout.writeln('C-FIND SERIES: ${series.length} in study $studyUid');

    final seriesQuery = Dataset()
      ..set(DicomTags.queryRetrieveLevel, 'SERIES')
      ..set(DicomTags.studyInstanceUid, studyUid)
      ..set(DicomTags.seriesInstanceUid, seriesUid);
    if (options['via'] == 'move') {
      // C-MOVE: the PACS opens its own association to our StorageScp.
      final scp = await StorageScp.start(
          aeTitle: options['calling-ae']!,
          port: int.parse(options['scp-port']!),
          sink: sink,
          acceptFrom: [ScpPeer(options['called-ae']!)]);
      try {
        await for (final p in assoc.sendCMove(seriesQuery,
            destination: options['calling-ae']!)) {
          stdout.writeln('C-MOVE: ${p.completed}/${p.total} completed, '
              '${p.failed} failed (${p.status})');
        }
      } finally {
        await scp.close();
      }
    } else {
      // C-GET: every instance of the series arrives on this association.
      await for (final p in assoc.sendCGet(seriesQuery, sink)) {
        stdout.writeln('C-GET: ${p.completed}/${p.total} completed, '
            '${p.failed} failed (${p.status})');
      }
    }
  } finally {
    await assoc.release();
  }

  // Display: the stored Part 10 file → pixels → 8-bit gray.
  final file = await sink.stored.first.readAsDicom();
  final ds = file.dataset;
  // The frame's own VOI, else the full range of its values.
  final buf = ds.pixels.frame(0).toDisplay();
  final pgm = File('${out.path}/frame0.pgm');
  await pgm.writeAsBytes([
    ...'P5\n${buf.width} ${buf.height}\n255\n'.codeUnits,
    ...buf.gray,
  ]);
  stdout.writeln('rendered ${buf.width}×${buf.height} → ${pgm.path}');
}
