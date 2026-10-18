// Modality LUT → VOI → 8-bit, on in-memory datasets (every platform).
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';
import 'package:test/test.dart';

import 'support/datasets.dart';

void main() {
  group('VoiWindow follows PS3.3 C.11.2.1.2.1', () {
    final w = VoiWindow(40, 400);
    test('below and above the window clip to black and white', () {
      expect(w.apply(-160.5), 0); // c - 0.5 - (w-1)/2 = -160
      expect(w.apply(-160), 0);
      expect(w.apply(239.6), 255); // c - 0.5 + (w-1)/2 = 239
      expect(w.apply(239), 255);
    });

    test('the center maps to mid-gray', () {
      expect(w.apply(39.5), 128);
    });

    test('a width of 1 is a threshold: up to center - 0.5 is black', () {
      final t = VoiWindow(100, 1);
      expect(t.apply(99.4), 0);
      expect(t.apply(99.5), 0); // x <= c - 0.5 (PS3.3; pydicom)
      expect(t.apply(99.6), 255);
    });

    test('a width below 1 is rejected', () {
      expect(() => VoiWindow(0, 0.5), throwsArgumentError);
    });
  });

  test('the Modality LUT runs before the window', () {
    // Stored 0 and 2048 with intercept -1024 are -1024 HU and +1024 HU.
    final ds = image16([0, 2048], signed: false, slope: 1, intercept: -1024);
    final buf = ds.pixels.frame(0).toDisplay(VoiWindow(0, 2048));
    expect(buf.gray, [0, 255]);
  });

  test('MONOCHROME1 inverts: the lowest value is white', () {
    final ds = image16([0, 1000], photometric: 'MONOCHROME1');
    expect(ds.pixels.frame(0).toDisplay(VoiWindow(500, 1000)).gray, [255, 0]);
  });

  test('voiWindow uses the first Window Center and Width', () {
    final ds = image16([0, 1])
      ..setAll(DicomTags.windowCenter, [40.0, -600.0])
      ..setAll(DicomTags.windowWidth, [400.0, 1500.0]);
    final w = ds.voiWindow();
    expect((w.center, w.width), (40.0, 400.0));
  });

  test('without a window, voiWindow spans the values, ignoring padding', () {
    final ds = image16([-2000, -1000, 0, 1000], padding: -2000);
    final buf = ds.pixels.frame(0).toDisplay(ds.voiWindow());
    expect(buf.gray.sublist(1), [0, 128, 255]);
  });

  test('toRgba repeats gray into opaque RGBA', () {
    final buf = DisplayBuffer(2, 1, Uint8List.fromList([10, 200]));
    expect(buf.toRgba(), [10, 10, 10, 255, 200, 200, 200, 255]);
  });

  test('a frame index out of range is a RangeError', () {
    expect(() => image16([1]).pixels.frame(1), throwsRangeError);
  });
}
