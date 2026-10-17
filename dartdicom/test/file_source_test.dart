// Random access, deferral and the async read (C-09, C-20, DA2, I-14). VM
// only: files on disk.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/io.dart';
import 'package:test/test.dart';

/// A CT fixture with 8 MiB of Pixel Data, written to [dir].
File _bigFile(Directory dir) {
  final file = DicomFile.fromBytes(
      File('../fixtures/data/synthetic/ct_signed_explicit_le.dcm')
          .readAsBytesSync());
  final pixels = Uint8List(8 << 20);
  for (var i = 0; i < pixels.length; i++) {
    pixels[i] = i & 0xFF;
  }
  file.dataset
    ..set(DicomTags.rows, 2048)
    ..set(DicomTags.columns, 2048)
    ..set(DicomTags.pixelData, pixels);
  return File('${dir.path}/big.dcm')..writeAsBytesSync(file.toBytes());
}

void main() {
  late Directory dir;
  late File big;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('dartdicom_source_');
    big = _bigFile(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a header-only read of a large file touches one window', () {
    final source = FileSource.open(big);
    final file = DicomFile.fromSource(source,
        options: const ReadOptions(stopBeforePixels: true));
    source.close();
    expect(file.dataset.get(DicomTags.rows), 2048);
    expect(file.dataset.contains(DicomTags.pixelData), isFalse);
    expect(source.bytesRead, lessThanOrEqualTo(FileSource.window));
  });

  test('a deferred value loads on first access, from the file', () {
    final source = FileSource.open(big);
    final ds = DicomFile.fromSource(source,
            options: const ReadOptions(deferSize: 1024))
        .dataset;
    source.close();
    expect(source.bytesRead, lessThanOrEqualTo(FileSource.window));
    final pixels = ds.require(DicomTags.pixelData);
    expect(pixels.length, 8 << 20);
    expect(pixels[1000], 1000 & 0xFF);
  });

  test('DA2: a changed file fails the deferred load', () {
    final ds = big
        .readAsDicomSync(options: const ReadOptions(deferSize: 1024))
        .dataset;
    big.setLastModifiedSync(DateTime.now().add(const Duration(days: 1)));
    expect(() => ds.get(DicomTags.pixelData),
        throwsA(isA<SourceChangedException>()));
  });

  test('I-14: a deferred dataset moves to another isolate and loads there',
      () async {
    final ds = big
        .readAsDicomSync(options: const ReadOptions(deferSize: 1024))
        .dataset;
    final length =
        await Isolate.run(() => ds.require(DicomTags.pixelData).length);
    expect(length, 8 << 20);
  });

  group('readAsDicom and readAsDicomSync agree', () {
    final fixtures = [
      for (final d in ['synthetic', 'pydicom'])
        ...Directory('../fixtures/data/$d')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.dcm')),
    ]..sort((a, b) => a.path.compareTo(b.path));
    for (final options in const [
      ReadOptions(),
      ReadOptions(stopBeforePixels: true),
      ReadOptions(deferSize: 64),
    ]) {
      test(
          'stopBeforePixels ${options.stopBeforePixels}, '
          'deferSize ${options.deferSize}', () async {
        for (final f in fixtures) {
          final DicomFile sync;
          try {
            sync = f.readAsDicomSync(options: options);
          } on DicomParseException {
            continue; // not readable yet (Deflated, Big Endian)
          }
          final async = await f.readAsDicom(options: options);
          expect(_flatten(async.dataset), _flatten(sync.dataset),
              reason: f.path);
        }
      });
    }

    test('on a large file, header-only', () async {
      final file = await big.readAsDicom(
          options: const ReadOptions(stopBeforePixels: true));
      expect(file.dataset.get(DicomTags.columns), 2048);
    });
  });

  test('a partial read is refused on write, so no data is dropped', () {
    final head =
        big.readAsDicomSync(options: const ReadOptions(stopBeforePixels: true));
    expect(
        head.toBytes,
        throwsA(isA<DicomWriteException>().having(
            (e) => e.message, 'message', contains('stopBeforePixels'))));
  });

  test('sequences nested beyond the limit are a parse error, not a crash', () {
    var item = Dataset()..set(DicomTags.codeMeaning, 'leaf');
    for (var i = 0; i < 70; i++) {
      item = Dataset()..set(DicomTags.contentSequence, Sequence([item]));
    }
    final bytes =
        item.toBytes(transferSyntax: TransferSyntaxes.explicitVrLittleEndian);
    expect(
        () => Dataset.fromBytes(bytes,
            transferSyntax: TransferSyntaxes.explicitVrLittleEndian),
        throwsA(isA<DicomParseException>()
            .having((e) => e.message, 'message', contains('nest'))));
  });
}

/// Every element, recursively, as (tag, VR, value) for comparison.
List<Object> _flatten(Dataset ds) => [
      for (final e in ds.elements)
        [
          e.tag.value,
          e.vr.code,
          switch (e.value) {
            final Sequence s => [for (final item in s) _flatten(item)],
            final Object v => v,
          },
        ],
    ];
