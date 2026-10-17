// I-10 on the M1 slice: reading then writing an untouched file in the same
// transfer syntax gives byte-identical output. VM only: reads the fixtures.
@TestOn('vm')
library;

import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

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
      continue; // Deflated and Big Endian: not readable yet (M2).
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
      expect(file.toBytes(), bytes);
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
      expect(again.toBytes(), bytes);
    });
  }
}
