// Native decoding on in-memory data (every platform, node and Chrome
// included): 1-bit, 32-bit, PlanarConfiguration 1, frames and views.
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';
import 'package:test/test.dart';

import 'support/datasets.dart';

List<int> _int32s(List<int> values, Endian endian) {
  final data = ByteData(values.length * 4);
  for (final (i, v) in values.indexed) {
    data.setUint32(i * 4, v & 0xFFFFFFFF, endian);
  }
  return data.buffer.asUint8List();
}

void main() {
  group('1-bit', () {
    // 3 frames of 3×5: 15 bits each, so frames 1 and 2 start inside a byte.
    final bits = [
      for (var i = 0; i < 45; i++) (i * 7 + i ~/ 3) % 3 == 0 ? 1 : 0
    ];
    final packed = Uint8List(6); // 45 bits, padded to even
    for (final (i, b) in bits.indexed) {
      packed[i ~/ 8] |= b << (i % 8); // least significant bit first
    }
    final ds = parsed([
      ...pixelModule(rows: 3, columns: 5, bitsAllocated: 1, frames: 3),
      (pixelDataTag, 'OB', packed),
    ]);

    test('unpacks least significant bit first, at each frame\'s bit offset',
        () {
      for (var f = 0; f < 3; f++) {
        expect(ds.pixels.frame(f).values, bits.sublist(f * 15, f * 15 + 15),
            reason: 'frame $f');
      }
      expect(ds.pixels.allFrames().values, bits);
    });

    test('is uint8, one byte per pixel', () {
      expect(ds.pixels.frame(1).dtype, PixelDtype.uint8);
    });
  });

  group('32-bit', () {
    test('signed, Bits Stored 32, keeps the full range', () {
      const values = [-2147483648, 2147483647, -1, 0, 123456789, -987654321];
      for (final endian in [Endian.little, Endian.big]) {
        final ds = parsed([
          ...pixelModule(
              rows: 2,
              columns: 3,
              bitsAllocated: 32,
              signed: true,
              endian: endian),
          (pixelDataTag, 'OW', _int32s(values, endian)),
        ], endian: endian);
        final f = ds.pixels.frame(0);
        expect(f.dtype, PixelDtype.int32);
        expect(f.values, values, reason: '$endian');
      }
    });

    test('unsigned, Bits Stored 32, keeps values past 2^31', () {
      const values = [0, 1, 2147483648, 4294967295];
      final ds = parsed([
        ...pixelModule(rows: 2, columns: 2, bitsAllocated: 32),
        (pixelDataTag, 'OW', _int32s(values, Endian.little)),
      ]);
      expect(ds.pixels.frame(0).values, values);
    });

    test('signed, Bits Stored 24, masks the top byte and sign-extends', () {
      // Low 24 bits: -1, 8388607, -8388608, 0; garbage in the top byte.
      const stored = [0xABFFFFFF, 0x127FFFFF, 0xFF800000, 0x01000000];
      final ds = parsed([
        ...pixelModule(
            rows: 1,
            columns: 4,
            bitsAllocated: 32,
            bitsStored: 24,
            signed: true),
        (pixelDataTag, 'OW', _int32s(stored, Endian.little)),
      ]);
      expect(ds.pixels.frame(0).values, [-1, 8388607, -8388608, 0]);
    });
  });

  test('PlanarConfiguration 1 is interleaved frame by frame', () {
    // Two 1×2 RGB frames, each as its R plane, G plane, B plane.
    final ds = parsed([
      ...pixelModule(
          rows: 1,
          columns: 2,
          bitsAllocated: 8,
          samples: 3,
          photometric: 'RGB',
          planar: 1,
          frames: 2),
      (pixelDataTag, 'OB', [1, 2, 3, 4, 5, 6, 11, 12, 13, 14, 15, 16]),
    ]);
    expect(ds.pixels.frame(0).values, [1, 3, 5, 2, 4, 6]);
    expect(ds.pixels.frame(1).values, [11, 13, 15, 12, 14, 16]);
    expect(ds.pixels.allFrames().shape,
        (frames: 2, rows: 1, columns: 2, samples: 3));
  });

  group('frames', () {
    final ds = image16([1, 2, 3, 4])
      ..set(DicomTags.columns, 2)
      ..set(DicomTags.numberOfFrames, 2);

    test('allFrames holds every frame; frame(i) views one of them', () {
      final all = ds.pixels.allFrames();
      expect(all.shape, (frames: 2, rows: 1, columns: 2, samples: 1));
      final second = all.frame(1);
      expect(second.values, [3, 4]);
      expect(second.firstFrame, 1);
      // Zero-copy throughout: a write to Pixel Data shows in the view.
      ds.require(DicomTags.pixelData)[4] = 9; // frame 1, first pixel
      expect(second.values.first, 9);
      expect(() => all.frame(2), throwsRangeError);
    });

    test('display and the modality range take one frame', () {
      final all = ds.pixels.allFrames();
      expect(() => all.toDisplay(VoiWindow(0, 10)), throwsStateError);
      expect(all.frame(0).toDisplay(VoiWindow(0, 10)).gray, hasLength(2));
    });
  });

  test('values are unmodifiable, even as a view of Pixel Data', () {
    final f = image16([1, 2]).pixels.frame(0);
    expect(() => f.values[0] = 7, throwsUnsupportedError);
  });
}
