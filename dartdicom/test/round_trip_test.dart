// I-10 under F41: reading then writing an untouched file in the same
// transfer syntax gives byte-identical output; for Deflated, the same header
// and the same inflated body. VM only: reads the fixtures.
@TestOn('vm')
library;

import 'dart:io';

import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/io.dart';
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
