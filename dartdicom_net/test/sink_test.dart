// DirectorySink: store as received (I-20), UID-only paths (I-21), whole or
// absent (F25). VM only: it writes files.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:test/test.dart';

ReceivedInstance _received(Dataset ds, Uid ts) => ReceivedInstance(
    sopClassUid: Uid(ds.require(DicomTags.sopClassUid)),
    sopInstanceUid: Uid(ds.require(DicomTags.sopInstanceUid)),
    transferSyntax: ts,
    bytes: ds.toBytes(transferSyntax: ts),
    sourceAeTitle: 'PEER');

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('dartdicom_sink_'));
  tearDown(() => root.deleteSync(recursive: true));

  final source = DicomFile.fromBytes(
          File('../fixtures/data/synthetic/ct_implicit_le.dcm')
              .readAsBytesSync())
      .dataset;

  test('I-20: the stored dataset bytes are the received bytes', () async {
    final instance = _received(source, TransferSyntaxes.implicitVrLittleEndian);
    final sink = DirectorySink(root);
    await sink.accept(instance);
    final stored = sink.stored.single.readAsBytesSync();
    final header = instance.fileMeta.toHeaderBytes();
    expect(stored.sublist(header.length), instance.bytes);
    final file = DicomFile.fromBytes(stored);
    expect(
        file.meta.transferSyntaxUid, TransferSyntaxes.implicitVrLittleEndian);
    expect(file.meta.sourceApplicationEntityTitle, 'PEER');
    expect(file.dataset.get(DicomTags.rows), source.get(DicomTags.rows));
  });

  test('I-21: every path is UIDs only, and no .part file is left', () async {
    final sink = DirectorySink(root);
    await sink
        .accept(_received(source, TransferSyntaxes.explicitVrLittleEndian));
    final paths = [
      for (final f in root.listSync(recursive: true).whereType<File>())
        f.path.substring(root.path.length + 1),
    ];
    expect(paths, [matches(RegExp(r'^[0-9.]+(/[0-9.]+)*\.dcm$'))]);
  });

  test('a UID that is not digits and dots is refused, nothing written',
      () async {
    final bad = Dataset()
      ..set(DicomTags.sopClassUid, SopClasses.ctImageStorage.value)
      ..set(DicomTags.sopInstanceUid, '1.2.3')
      ..set(DicomTags.studyInstanceUid, '../../etc')
      ..set(DicomTags.seriesInstanceUid, '1.2.3.4');
    final sink = DirectorySink(root);
    await expectLater(
        sink.accept(_received(bad, TransferSyntaxes.explicitVrLittleEndian)),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', isNot(contains('etc')))));
    expect(root.listSync(recursive: true), isEmpty);
  });

  test('MemorySink keeps instances in order', () async {
    final sink = MemorySink();
    final one = _received(source, TransferSyntaxes.explicitVrLittleEndian);
    await sink.accept(one);
    await sink.accept(ReceivedInstance(
        sopClassUid: one.sopClassUid,
        sopInstanceUid: const Uid('9.9'),
        transferSyntax: one.transferSyntax,
        bytes: Uint8List(0),
        sourceAeTitle: 'PEER'));
    expect([for (final i in sink.instances) i.sopInstanceUid.value],
        [one.sopInstanceUid.value, '9.9']);
  });
}
