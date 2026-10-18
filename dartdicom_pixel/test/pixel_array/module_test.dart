// The Image Pixel module is checked as pydicom checks it, and every failure
// is a PixelDataException naming the tag, never a value (I-9).
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';
import 'package:test/test.dart';

import '../support/datasets.dart';

TypeMatcher<InvalidPixelModule> _invalid(Tag tag) =>
    isA<InvalidPixelModule>().having((e) => e.tag, 'tag', tag);

TypeMatcher<UnsupportedPixelEncoding> _unsupported(Tag tag) =>
    isA<UnsupportedPixelEncoding>().having((e) => e.tag, 'tag', tag);

void main() {
  group('a required attribute that is absent is an InvalidPixelModule', () {
    for (final tag in [
      DicomTags.samplesPerPixel,
      DicomTags.photometricInterpretation,
      DicomTags.rows,
      DicomTags.columns,
      DicomTags.bitsAllocated,
      DicomTags.bitsStored,
      DicomTags.pixelRepresentation,
    ]) {
      test(Dictionary.standard.entry(tag)!.keyword, () {
        final ds = image16([1, 2])..remove(tag);
        expect(() => ds.pixels, throwsA(_invalid(tag)));
      });
    }

    test('Planar Configuration, when there are three samples', () {
      final ds = image16([1, 2])
        ..set(DicomTags.samplesPerPixel, 3)
        ..set(DicomTags.photometricInterpretation, 'RGB');
      expect(() => ds.pixels, throwsA(_invalid(DicomTags.planarConfiguration)));
    });

    test('Pixel Data, naming stopBeforePixels', () {
      final ds = image16([1, 2])..remove(DicomTags.pixelData);
      expect(
          () => ds.pixels.frame(0),
          throwsA(_invalid(DicomTags.pixelData).having(
              (e) => e.message, 'message', contains('stopBeforePixels'))));
    });
  });

  group('a value out of range is an InvalidPixelModule', () {
    void expectInvalid(Tag tag, void Function(Dataset) edit) {
      final ds = image16([1, 2]);
      edit(ds);
      expect(() => ds.pixels, throwsA(_invalid(tag)));
    }

    test('Rows 0', () {
      expectInvalid(DicomTags.rows, (ds) => ds.set(DicomTags.rows, 0));
    });
    test('Bits Allocated 12', () {
      expectInvalid(
          DicomTags.bitsAllocated, (ds) => ds.set(DicomTags.bitsAllocated, 12));
    });
    test('Bits Stored above Bits Allocated', () {
      expectInvalid(
          DicomTags.bitsStored, (ds) => ds.set(DicomTags.bitsStored, 17));
    });
    test('Pixel Representation 2', () {
      expectInvalid(DicomTags.pixelRepresentation,
          (ds) => ds.set(DicomTags.pixelRepresentation, 2));
    });
    test('Samples per Pixel 2', () {
      expectInvalid(DicomTags.samplesPerPixel,
          (ds) => ds.set(DicomTags.samplesPerPixel, 2));
    });
    test('an unknown Photometric Interpretation', () {
      expectInvalid(DicomTags.photometricInterpretation,
          (ds) => ds.set(DicomTags.photometricInterpretation, 'GRAYSCALE'));
    });
  });

  test('Number of Frames 0 is one frame, as in pydicom', () {
    final ds = image16([1, 2])..set(DicomTags.numberOfFrames, 0);
    expect(ds.pixels.numberOfFrames, 1);
    expect(ds.pixels.frame(0).values, [1, 2]);
  });

  group('an encoding this version cannot decode is UnsupportedPixelEncoding',
      () {
    test('a compressed transfer syntax, named by a field', () {
      final ds = parsed(pixelModule(rows: 1, columns: 2, bitsAllocated: 8),
          transferSyntax: TransferSyntaxes.rleLossless);
      expect(
          () => ds.pixels.frame(0),
          throwsA(isA<UnsupportedPixelEncoding>()
              .having((e) => e.transferSyntax, 'transferSyntax',
                  TransferSyntaxes.rleLossless)
              .having((e) => e.message, 'message',
                  isNot(contains(TransferSyntaxes.rleLossless.value)))));
    });

    test('Bits Allocated 24, with no value in the message', () {
      final ds = parsed([
        ...pixelModule(rows: 1, columns: 2, bitsAllocated: 24),
        (pixelDataTag, 'OB', List.filled(6, 0)),
      ]);
      expect(
          () => ds.pixels.frame(0),
          throwsA(_unsupported(DicomTags.bitsAllocated)
              .having((e) => e.message, 'message', isNot(contains('24')))));
    });

    test('YBR_FULL_422', () {
      final ds = parsed([
        ...pixelModule(
            rows: 1,
            columns: 2,
            bitsAllocated: 8,
            samples: 3,
            planar: 0,
            photometric: 'YBR_FULL_422'),
        (pixelDataTag, 'OB', [1, 2, 3, 4]),
      ]);
      expect(() => ds.pixels.frame(0),
          throwsA(_unsupported(DicomTags.photometricInterpretation)));
    });

    test('displaying RGB or PALETTE COLOR', () {
      final rgb = parsed([
        ...pixelModule(
            rows: 1,
            columns: 1,
            bitsAllocated: 8,
            samples: 3,
            planar: 0,
            photometric: 'RGB'),
        (pixelDataTag, 'OB', [1, 2, 3, 0]),
      ]);
      final palette = parsed([
        ...pixelModule(
            rows: 1,
            columns: 2,
            bitsAllocated: 8,
            photometric: 'PALETTE COLOR'),
        (pixelDataTag, 'OB', [1, 2]),
      ]);
      for (final ds in [rgb, palette]) {
        final frame = ds.pixels.frame(0); // the values still decode
        expect(() => frame.toDisplay(VoiWindow(128, 256)),
            throwsA(_unsupported(DicomTags.photometricInterpretation)));
      }
    });
  });

  test('MONOCHROME with three samples decodes, but does not display', () {
    // Found by the fuzz: the buffer would hold three bytes per pixel.
    final ds = parsed([
      ...pixelModule(
          rows: 1, columns: 1, bitsAllocated: 8, samples: 3, planar: 0),
      (pixelDataTag, 'OB', [1, 2, 3, 0]),
    ]);
    final frame = ds.pixels.frame(0);
    expect(frame.values, [1, 2, 3]);
    expect(
        () => frame.toDisplay(), throwsA(_invalid(DicomTags.samplesPerPixel)));
  });

  group('Pixel Data that does not hold the frame is an InvalidPixelModule', () {
    test('shorter than one frame', () {
      final ds = image16([1, 2])
        ..set(DicomTags.pixelData, Uint8List.fromList([1, 0]));
      expect(() => ds.pixels.frame(0), throwsA(_invalid(DicomTags.pixelData)));
    });

    test('a later frame missing', () {
      final ds = image16([1, 2])..set(DicomTags.numberOfFrames, 2);
      expect(ds.pixels.frame(0).values, [1, 2]);
      expect(() => ds.pixels.frame(1), throwsA(_invalid(DicomTags.pixelData)));
    });

    test('huge declared sizes are refused before anything is allocated', () {
      final ds = image16([1, 2])
        ..set(DicomTags.rows, 65535)
        ..set(DicomTags.columns, 65535)
        ..set(DicomTags.numberOfFrames, 2147483647);
      expect(() => ds.pixels.frame(2147483646),
          throwsA(_invalid(DicomTags.pixelData)));
    });
  });

  test('8-bit OW Big Endian swaps pairs from the start of the value', () {
    // Two 1×3 frames: each frame is 3 bytes, so frame 1 starts on an odd
    // byte. Stored as 16-bit Big Endian words, the pixels 10…15 are
    // 11 10 13 12 15 14 (pydicom's be_swap_ow).
    final ds = parsed([
      ...pixelModule(
          rows: 1, columns: 3, bitsAllocated: 8, frames: 2, endian: Endian.big),
      (pixelDataTag, 'OW', [11, 10, 13, 12, 15, 14]),
    ], endian: Endian.big);
    expect(ds.pixels.frame(0).values, [10, 11, 12]);
    expect(ds.pixels.frame(1).values, [13, 14, 15]);
  });

  test('a frame has a shape and a dtype', () {
    final f = image16([1, -2, 3]).pixels.frame(0);
    expect(f.shape, (frames: 1, rows: 1, columns: 3, samples: 1));
    expect(f.dtype, PixelDtype.int16);
    expect(f.values, isA<Int16List>());
  });

  test('every failure is a PixelDataException under DicomException', () {
    Object? caught;
    try {
      (image16([1])..remove(DicomTags.rows)).pixels;
    } on DicomException catch (e) {
      caught = e;
    }
    final kind = switch (caught! as PixelDataException) {
      UnsupportedPixelEncoding() => 'unsupported',
      InvalidPixelModule() => 'invalid',
    };
    expect(kind, 'invalid');
    expect(
        '$caught',
        'InvalidPixelModule: (0028,0010) Rows is required for '
            'Pixel Data');
  });
}
