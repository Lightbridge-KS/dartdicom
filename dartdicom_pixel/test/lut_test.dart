// The LUTs agree with pydicom on every grayscale native fixture (I-33):
// modality values bit for bit, and every VOI within one gray level, against
// fixtures/data/lut/ (blueprint F47).
// VM only: reads the fixtures.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';
import 'package:test/test.dart';

import 'support/golden.dart';

void main() {
  final goldens = lutGoldens(Directory('../fixtures/data/lut'));

  test('every grayscale native fixture has a LUT golden', () {
    expect(goldens.length, greaterThanOrEqualTo(30));
  });

  test('the VOI check catches a pixel two gray levels off', () {
    // ct_sigmoid's first window, with one pixel of pydicom's moved by 2.
    final golden =
        goldens.firstWhere((g) => g.file == 'synthetic/ct_sigmoid.dcm');
    final variant = golden.frames.first.voi.first;
    final gray = Uint8List.fromList(variant.gray!);
    gray[100] = gray[100] < 128 ? gray[100] + 2 : gray[100] - 2;
    final ds = DicomFile.fromBytes(
            File('../fixtures/data/synthetic/ct_sigmoid.dcm').readAsBytesSync())
        .dataset;
    expect(voiMismatch(ds, ds.pixels.frame(0), variant), isNull);
    final moved = (
      kind: variant.kind,
      index: variant.index,
      error: variant.error,
      gray: gray,
    );
    expect(voiMismatch(ds, ds.pixels.frame(0), moved),
        contains('2 gray levels off'));
  });

  for (final golden in goldens) {
    final path = golden.file;
    final ds =
        DicomFile.fromBytes(File('../fixtures/data/$path').readAsBytesSync())
            .dataset;

    test('$path: modality values equal apply_modality_lut, frame by frame', () {
      final px = ds.pixels;
      expect(px.numberOfFrames, golden.frames.length);
      for (final (f, frame) in golden.frames.indexed) {
        expect(modalitySha(px.frame(f).toModality()), frame.modality,
            reason: 'frame $f');
      }
    });

    final variants = [
      for (final (f, frame) in golden.frames.indexed)
        for (final v in frame.voi) (f, v),
    ];
    if (variants.isEmpty) continue;
    test('$path: each VOI is within one gray level of apply_voi_lut', () {
      final px = ds.pixels;
      for (final (f, variant) in variants) {
        expect(voiMismatch(ds, px.frame(f), variant), isNull,
            reason: 'frame $f, ${variant.kind} ${variant.index}');
      }
    });
  }
}
