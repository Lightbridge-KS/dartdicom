// The LUTs agree with pydicom on every grayscale native fixture (I-33):
// modality values bit for bit, and every VOI within one gray level, against
// fixtures/data/lut/ (blueprint F47).
// VM only: reads the fixtures.
@TestOn('vm')
library;

import 'dart:convert';
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

  test('the VOI check catches a pixel two gray levels off', () {
    // ct_sigmoid's first window, with one pixel of pydicom's moved by 2.
    final record =
        records.firstWhere((r) => r['file'] == 'synthetic/ct_sigmoid.dcm');
    final frame =
        (record['frames']! as List<Object?>).first! as Map<String, Object?>;
    final variant =
        (frame['voi']! as List<Object?>).first! as Map<String, Object?>;
    final gray = base64Decode(variant['gray']! as String);
    gray[100] = gray[100] < 128 ? gray[100] + 2 : gray[100] - 2;
    final ds = DicomFile.fromBytes(
            File('../fixtures/data/synthetic/ct_sigmoid.dcm').readAsBytesSync())
        .dataset;
    expect(voiMismatch(ds, ds.pixels.frame(0), variant), isNull);
    expect(
        voiMismatch(
            ds, ds.pixels.frame(0), {...variant, 'gray': base64Encode(gray)}),
        contains('2 gray levels off'));
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

    final variants = [
      for (final (f, golden) in frames.indexed)
        for (final v
            in (golden['voi']! as List<Object?>).cast<Map<String, Object?>>())
          (f, v),
    ];
    if (variants.isEmpty) continue;
    test('$path: each VOI is within one gray level of apply_voi_lut', () {
      final px = ds.pixels;
      for (final (f, variant) in variants) {
        expect(voiMismatch(ds, px.frame(f), variant), isNull,
            reason: 'frame $f, ${variant['kind']} ${variant['index']}');
      }
    });
  }
}
