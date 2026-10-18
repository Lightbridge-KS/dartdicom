// The PHI canary through the pixel pipeline (I-9): the phi_canary fixture
// carries a marker (ZXQV) in names, IDs, descriptions, a private element and
// nested sequence text. Decoding, the LUTs and display, and every failure
// along the way, must never show it. The marker also goes into the text
// attributes the pixel code reads itself. VM only: reads the fixture.
@TestOn('vm')
library;

import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';
import 'package:test/test.dart';

final _marker = RegExp('zxqv', caseSensitive: false);

Dataset _canary() => DicomFile.fromBytes(
        File('../fixtures/data/synthetic/phi_canary.dcm').readAsBytesSync())
    .dataset;

void main() {
  test('the canary carries the marker', () {
    expect('${_canary().get(DicomTags.patientName)}', matches(_marker));
  });

  test('no toString along the pipeline shows a value of the canary', () {
    final ds = _canary()
      ..setAll(DicomTags.windowCenter, [1.0])
      ..setAll(DicomTags.windowWidth, [4.0])
      ..setAll(DicomTags.windowCenterWidthExplanation, ['ZXQV explanation']);
    final px = ds.pixels;
    final frame = px.frame(0);
    final shown = [
      '$px',
      '${px.module}',
      '$frame',
      '${px.allFrames()}',
      '${ds.voi()}',
      '${frame.autoWindow()}',
      '${frame.toDisplay()}',
      '${frame.toModality()}',
    ];
    for (final s in shown) {
      expect(s, isNot(matches(_marker)), reason: s);
    }
  });

  test('no failure shows a value, even one the pixel code read itself', () {
    final failures = <void Function()>[
      // The marker as the attributes pixel code reads as text.
      () =>
          (_canary()..set(DicomTags.photometricInterpretation, 'ZXQV')).pixels,
      () => (_canary()
            ..setAll(DicomTags.windowCenter, [1.0])
            ..setAll(DicomTags.windowWidth, [4.0])
            ..set(DicomTags.voilutFunction, 'ZXQV'))
          .voi(),
      () => (_canary()
            ..set(DicomTags.photometricInterpretation, 'RGB')
            ..set(DicomTags.samplesPerPixel, 3)
            ..set(DicomTags.planarConfiguration, 0))
          .pixels
          .frame(0),
      // And the usual ways for pixels to fail.
      () => (_canary()..remove(DicomTags.rows)).pixels,
      () => (_canary()..remove(DicomTags.pixelData)).pixels.frame(0),
      () => (_canary()..set(DicomTags.bitsAllocated, 24)).pixels.frame(0),
      () => (_canary()..set(DicomTags.numberOfFrames, 9)).pixels.frame(8),
      () => (_canary()
            ..setAll(DicomTags.windowCenter, [1.0])
            ..setAll(DicomTags.windowWidth, [0.5]))
          .voi(),
      () => (_canary()
            ..set(
                DicomTags.voilutSequence,
                Sequence([
                  Dataset()
                    ..setRaw(DicomTags.lutDescriptor, Vr.US, [4, 0, 16])
                    ..setRaw(DicomTags.lutData, Vr.US, [1]),
                ])))
          .voi(),
    ];
    for (final (i, fail) in failures.indexed) {
      final message = switch (_caught(fail)) {
        final PixelDataException e => e.message,
        final Object e => throw StateError('case $i threw ${e.runtimeType}'),
      };
      expect(message, isNot(matches(_marker)), reason: 'case $i: $message');
    }
  });
}

Object _caught(void Function() body) {
  try {
    body();
  } on Object catch (e) {
    return e;
  }
  throw StateError('no failure');
}
