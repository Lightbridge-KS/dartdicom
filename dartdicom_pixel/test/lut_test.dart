// The LUTs agree with pydicom on every grayscale native fixture (I-33):
// modality values bit for bit, against fixtures/data/lut/ (blueprint F47).
// VM only: reads the fixtures.
@TestOn('vm')
library;

import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';
import 'package:test/test.dart';

import 'support/golden.dart';

void main() {
  final records = lutRecords(Directory('../fixtures/data/lut'));

  test('every grayscale native fixture has a LUT golden', () {
    expect(records.length, greaterThanOrEqualTo(30));
  });

  for (final record in records) {
    final path = record['file']! as String;
    final frames =
        (record['frames']! as List<Object?>).cast<Map<String, Object?>>();
    final ds =
        DicomFile.fromBytes(File('../fixtures/data/$path').readAsBytesSync())
            .dataset;

    test('$path: modality values equal apply_modality_lut, frame by frame', () {
      final px = ds.pixels;
      expect(px.numberOfFrames, frames.length);
      for (final (f, golden) in frames.indexed) {
        expect(modalitySha(px.frame(f).toModality()), golden['modality'],
            reason: 'frame $f');
      }
    });
  }
}
