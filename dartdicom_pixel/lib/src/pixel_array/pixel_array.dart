import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';

import '../display/display_buffer.dart';
import '../errors.dart';
import '../lut/voi_window.dart';
import 'pixel_module.dart';

/// The shape of a [PixelArray]: frames, then rows, columns and samples per
/// pixel, in that order (pydicom's C order, with every axis kept).
typedef PixelShape = ({int frames, int rows, int columns, int samples});

/// The Dart type of a [PixelArray]'s values, like a NumPy dtype.
enum PixelDtype {
  uint8(8, false),
  int8(8, true),
  uint16(16, false),
  int16(16, true),
  uint32(32, false),
  int32(32, true);

  const PixelDtype(this.bits, this.signed);

  /// The dtype [module]'s stored values decode to. 1-bit data unpacks to
  /// one byte per pixel, unsigned whatever the Pixel Representation.
  factory PixelDtype.of(PixelModule module) =>
      switch ((module.bitsAllocated, module.signed)) {
        (1, _) => uint8,
        (8, false) => uint8,
        (8, true) => int8,
        (16, false) => uint16,
        (16, true) => int16,
        (32, false) => uint32,
        (32, true) => int32,
        _ => throw UnsupportedPixelEncoding(
            'is not one this version decodes (1, 8, 16 or 32)',
            tag: DicomTags.bitsAllocated),
      };

  /// Bits per value.
  final int bits;

  /// Whether the values are two's complement.
  final bool signed;
}

/// One decoded frame: the stored pixel values plus their shape (PRD X-01).
///
/// [values] is a typed list (`Int16List`, `Uint16List`, `Uint8List`, …),
/// row by row, samples interleaved. It is a zero-copy view of Pixel Data
/// where the bytes allow, and a copy when they need masking, sign extension
/// or byte swapping.
final class PixelArray {
  PixelArray(this.values, this.module) : dtype = PixelDtype.of(module);

  /// The stored values, before any LUT.
  final List<int> values;

  /// The pixel module the frame was decoded with.
  final PixelModule module;

  /// The Dart type of [values].
  final PixelDtype dtype;

  /// (frames, rows, columns, samples).
  PixelShape get shape => (
        frames: 1,
        rows: module.rows,
        columns: module.columns,
        samples: module.samplesPerPixel,
      );

  /// Rows.
  int get rows => module.rows;

  /// Columns.
  int get columns => module.columns;

  /// Samples per pixel: 1 for grayscale.
  int get samplesPerPixel => module.samplesPerPixel;

  /// Applies the Modality LUT (rescale slope and intercept), then [window],
  /// then MONOCHROME1 inversion, giving 8-bit gray (PRD X-04, X-07).
  ///
  /// Throws an [UnsupportedPixelEncoding] for anything but MONOCHROME1 and
  /// MONOCHROME2: color and palette display is X-08.
  DisplayBuffer toDisplay(VoiWindow window) {
    if (!module.isMonochrome) {
      throw UnsupportedPixelEncoding(
          'is not MONOCHROME1 or MONOCHROME2: displaying color or palette '
          'images is not supported yet (X-08); the decoded values are in '
          '`values`',
          tag: DicomTags.photometricInterpretation);
    }
    final slope = module.rescaleSlope;
    final intercept = module.rescaleIntercept;
    final invert = module.photometricInterpretation == 'MONOCHROME1';
    final gray = Uint8List(values.length);
    for (var i = 0; i < values.length; i++) {
      final level = window.apply(values[i] * slope + intercept);
      gray[i] = invert ? 255 - level : level;
    }
    return DisplayBuffer(columns, rows, gray);
  }

  /// The smallest and largest modality values, ignoring the Pixel Padding
  /// Value, or `null` if every pixel is padding.
  (double, double)? modalityRange() {
    final padding = module.pixelPaddingValue;
    int? lo;
    int? hi;
    for (final v in values) {
      if (v == padding) continue;
      if (lo == null || v < lo) lo = v;
      if (hi == null || v > hi) hi = v;
    }
    if (lo == null || hi == null) return null;
    final a = lo * module.rescaleSlope + module.rescaleIntercept;
    final b = hi * module.rescaleSlope + module.rescaleIntercept;
    return a <= b ? (a, b) : (b, a);
  }

  @override
  String toString() => 'PixelArray($rows × $columns × $samplesPerPixel, '
      '${dtype.name})';
}
