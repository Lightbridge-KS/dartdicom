// The VOI on in-memory data (every platform): the window functions, the
// VOI LUT, the dataset's VOI per frame, and toDisplay's default and fold.
import 'dart:math' as math;

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';
import 'package:test/test.dart';

import '../support/datasets.dart';

TypeMatcher<InvalidPixelModule> _invalid(Tag tag) =>
    isA<InvalidPixelModule>().having((e) => e.tag, 'tag', tag);

Dataset _lutItem(List<int> descriptor, List<int> entries) => Dataset()
  ..setRaw(DicomTags.lutDescriptor, Vr.US, descriptor)
  ..setRaw(DicomTags.lutData, Vr.US, entries);

void main() {
  group('VoiWindow', () {
    test('LINEAR follows PS3.3 C.11.2.1.2.1', () {
      final w = VoiWindow(40, 400);
      expect(w.apply(-160), 0); // c - 0.5 - (w-1)/2
      expect(w.apply(39.5), 128);
      expect(w.apply(239), 255); // past c - 0.5 + (w-1)/2
    });

    test('LINEAR_EXACT has no half-level shift, and any width above 0', () {
      final w = VoiWindow(40, 400, function: VoiFunction.linearExact);
      expect(w.apply(-160), 0); // c - w/2
      expect(w.apply(40), 128); // ((x - c)/w + 0.5) × 255 = 127.5
      expect(w.apply(240.1), 255);
      expect(VoiWindow(50, 0.5, function: VoiFunction.linearExact).apply(50.3),
          255);
    });

    test('SIGMOID follows PS3.3 C.11.2.1.3.1', () {
      final w = VoiWindow(40, 400, function: VoiFunction.sigmoid);
      expect(w.apply(40), 128); // 255 / 2
      final x = 140.0;
      expect(w.apply(x), (255 / (1 + math.exp(-4 * (x - 40) / 400))).round());
    });

    test('a width outside the function\'s range is an ArgumentError', () {
      expect(() => VoiWindow(0, 0.5), throwsArgumentError);
      expect(() => VoiWindow(0, 0, function: VoiFunction.sigmoid),
          throwsArgumentError);
      expect(() => VoiWindow(double.nan, 10), throwsArgumentError);
    });
  });

  group('VoiLut', () {
    test('scales by its bits per entry and clamps entries above them', () {
      final lut =
          VoiLut(firstMapped: -1, bitsPerEntry: 12, entries: [0, 4095, 9999]);
      expect(lut.apply(-5), 0); // below the first mapped value
      expect(lut.apply(0), 255); // 4095 of 4095
      expect(lut.apply(1), 255); // 9999, clamped to 4095
      expect(lut.apply(-0.1), 0); // -0.1 truncates to the entry for -1
    });

    test('an infinite input takes an end of the table', () {
      final lut = VoiLut(firstMapped: 0, bitsPerEntry: 8, entries: [0, 255]);
      expect(lut.apply(double.infinity), 255);
      expect(lut.apply(double.negativeInfinity), 0);
    });

    test('takes 8–16 bits and at least one entry', () {
      expect(() => VoiLut(firstMapped: 0, bitsPerEntry: 7, entries: [1]),
          throwsArgumentError);
      expect(() => VoiLut(firstMapped: 0, bitsPerEntry: 17, entries: [1]),
          throwsArgumentError);
      expect(() => VoiLut(firstMapped: 0, bitsPerEntry: 8, entries: const []),
          throwsArgumentError);
    });
  });

  group('ds.voi()', () {
    Dataset windowed() => image16([0, 100])
      ..setAll(DicomTags.windowCenter, [40.0, -600.0])
      ..setAll(DicomTags.windowWidth, [400.0, 1500.0]);

    test('a VOI LUT wins over a window unless preferLut is false', () {
      final ds = windowed()
        ..set(
            DicomTags.voilutSequence,
            Sequence([
              _lutItem([2, 0, 8], [0, 255])
            ]));
      expect(ds.voi(), isA<VoiLut>());
      expect(ds.voi(preferLut: false), isA<VoiWindow>());
    });

    test('a single Center or Width is kept for every index, as pydicom', () {
      final ds = image16([0])
        ..setAll(DicomTags.windowCenter, [40.0, 50.0])
        ..setAll(DicomTags.windowWidth, [400.0]);
      final w = ds.voi(index: 1)! as VoiWindow;
      expect((w.center, w.width), (50.0, 400.0));
      expect(() => windowed().voi(index: 2), throwsRangeError);
    });

    test('reads the VOI LUT Function, case-insensitively', () {
      final ds = windowed()..set(DicomTags.voilutFunction, 'sigmoid');
      expect((ds.voi()! as VoiWindow).function, VoiFunction.sigmoid);
      ds.set(DicomTags.voilutFunction, 'GAMMA');
      expect(
          ds.voi,
          throwsA(isA<UnsupportedPixelEncoding>()
              .having((e) => e.tag, 'tag', DicomTags.voilutFunction)));
    });

    test('an invalid window is an InvalidPixelModule, with no value shown', () {
      final narrow = image16([0])
        ..setAll(DicomTags.windowCenter, [40.0])
        ..setAll(DicomTags.windowWidth, [0.25]);
      expect(
          narrow.voi,
          throwsA(_invalid(DicomTags.windowWidth)
              .having((e) => e.message, 'message', isNot(contains('0.25')))));
      // LINEAR_EXACT takes it.
      narrow.set(DicomTags.voilutFunction, 'LINEAR_EXACT');
      expect((narrow.voi()! as VoiWindow).width, 0.25);
    });

    test('each frame takes its own Frame VOI LUT item', () {
      Dataset voiGroup(double center) => Dataset()
        ..set(
            DicomTags.frameVoilutSequence,
            Sequence([
              Dataset()
                ..setAll(DicomTags.windowCenter, [center])
                ..setAll(DicomTags.windowWidth, [100.0]),
            ]));
      final ds = windowed()
        ..set(DicomTags.columns, 1)
        ..set(DicomTags.numberOfFrames, 2)
        ..set(DicomTags.perFrameFunctionalGroupsSequence,
            Sequence([Dataset(), voiGroup(-50)]))
        ..set(
            DicomTags.sharedFunctionalGroupsSequence, Sequence([voiGroup(77)]));
      expect((ds.voi()! as VoiWindow).center, 77);
      expect((ds.voi(frame: 1)! as VoiWindow).center, -50);
      // toDisplay() uses each frame's own: stored 0 and 100, one per frame.
      final all = ds.pixels.allFrames();
      expect(all.frame(0).toDisplay().gray,
          all.frame(0).toDisplay(VoiWindow(77, 100)).gray);
      expect(all.frame(1).toDisplay().gray,
          all.frame(1).toDisplay(VoiWindow(-50, 100)).gray);
    });
  });

  test('the folded table gives what the per-pixel path gives', () {
    // 300 values of 8 bits: enough for the 256-entry table.
    final values = [for (var i = 0; i < 300; i++) (i * 37) % 256 - 128];
    final ds = parsed([
      ...pixelModule(
          rows: 1, columns: values.length, bitsAllocated: 8, signed: true),
      (pixelDataTag, 'OB', [for (final v in values) v & 0xFF]),
    ]);
    final window = VoiWindow(10, 120, function: VoiFunction.sigmoid);
    final gray = ds.pixels.frame(0).toDisplay(window).gray;
    expect(gray, [for (final v in values) window.apply(v.toDouble())]);
  });
}
