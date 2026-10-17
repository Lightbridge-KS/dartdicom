// I-10 under F41: reading then writing an untouched file in the same
// transfer syntax gives byte-identical output; for Deflated, the same header
// and the same inflated body. VM only: reads the fixtures.
@TestOn('vm')
library;

import 'dart:io';

import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/io.dart';
import 'package:dartdicom/src/write/writer.dart' show swapWords;
import 'package:test/test.dart';

const _zlib = WriteOptions(deflateCodec: ZLibDeflateCodec());

/// I-10's comparison under F41: identical bytes, or for Deflated, an
/// identical header and inflated body.
void _expectSame(DicomFile file, Uint8List written, Uint8List read) {
  if (file.meta.transferSyntaxUid !=
      TransferSyntaxes.deflatedExplicitVrLittleEndian) {
    expect(written, read);
    return;
  }
  final int groupLength =
      file.meta.dataset.require(DicomTags.fileMetaInformationGroupLength);
  final metaEnd = 144 + groupLength;
  expect(written.sublist(0, metaEnd), read.sublist(0, metaEnd));
  const zlib = ZLibDeflateCodec();
  expect(zlib.inflate(Uint8List.sublistView(written, metaEnd)),
      zlib.inflate(Uint8List.sublistView(read, metaEnd)));
}

void main() {
  final fixtures = [
    for (final dir in ['synthetic', 'pydicom'])
      ...Directory('../fixtures/data/$dir')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dcm')),
  ]..sort((a, b) => a.path.compareTo(b.path));

  for (final fixture in fixtures) {
    final name = fixture.uri.pathSegments
        .skip(fixture.uri.pathSegments.length - 2)
        .join('/');
    final bytes = fixture.readAsBytesSync();
    final DicomFile file;
    try {
      file = DicomFile.fromBytes(bytes);
    } on DicomParseException {
      continue; // Big Endian: not readable yet (M2 step 4b).
    }

    // A few public files carry file meta whose SOP UIDs contradict the
    // dataset's. Reading is lenient; writing is strict, so I-17 refuses them
    // rather than copy the contradiction (data §5).
    final metaUid = file.meta.mediaStorageSopInstanceUid?.value;
    final datasetUid = file.dataset.get(DicomTags.sopInstanceUid);
    if (metaUid != null && datasetUid != null && metaUid != datasetUid) {
      test('$name has contradicting SOP UIDs, so the write is refused', () {
        expect(file.toBytes, throwsA(isA<DicomWriteException>()));
      });
      continue;
    }

    // F41: Big Endian is read-only, so I-10 doesn't apply. Writing it is
    // refused with the fix named, and the Little Endian rewrite reads back
    // the same elements.
    if (file.meta.transferSyntaxUid == TransferSyntaxes.explicitVrBigEndian) {
      test('$name (Big Endian) is refused as written, and rewrites as LE', () {
        expect(
            file.toBytes,
            throwsA(isA<DicomWriteException>().having((e) => e.message,
                'message', contains('explicitVrLittleEndian'))));
        final le = DicomFile.fromBytes(file.toBytes(
            options: const WriteOptions(
                transferSyntax: TransferSyntaxes.explicitVrLittleEndian)));
        expect(
            le.meta.transferSyntaxUid, TransferSyntaxes.explicitVrLittleEndian);
        // Everything decodes the same; OW Pixel Data words swap (I-18).
        expect(_flatten(le.dataset, skip: DicomTags.pixelData),
            _flatten(file.dataset, skip: DicomTags.pixelData));
        final be = file.dataset.require(DicomTags.pixelData);
        final int bitsAllocated = file.dataset.require(DicomTags.bitsAllocated);
        expect(le.dataset.require(DicomTags.pixelData),
            swapWords(be, bitsAllocated > 16 ? bitsAllocated ~/ 8 : 2));
      });
      continue;
    }

    test('$name round-trips byte for byte', () {
      _expectSame(file, file.toBytes(options: _zlib), bytes);
    });

    test('$name round-trips after every value was read', () {
      final again = DicomFile.fromBytes(bytes);
      void touch(Dataset ds) {
        for (final e in ds.elements) {
          final value = e.value;
          if (value is Sequence) value.forEach(touch);
        }
      }

      touch(again.meta.dataset);
      touch(again.dataset);
      _expectSame(again, again.toBytes(options: _zlib), bytes);
    });
  }
}

/// Every element, recursively, as [tag, VR, value] for comparison.
List<Object> _flatten(Dataset ds, {Tag? skip}) => [
      for (final e in ds.elements.where((e) => e.tag != skip))
        [
          e.tag.value,
          e.vr.code,
          switch (e.value) {
            final Sequence s => [for (final item in s) _flatten(item)],
            final Object v => v,
          },
        ],
    ];
