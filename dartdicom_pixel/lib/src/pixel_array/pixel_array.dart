import 'dart:typed_data';

import '../display/display_buffer.dart';
import '../lut/voi_window.dart';
import 'pixel_module.dart';

/// One decoded frame: the stored pixel values plus their shape (PRD X-01).
///
/// [values] is a typed list (`Int16List`, `Uint16List`, `Uint8List`, …),
/// row by row. It is a zero-copy view of Pixel Data where the bytes allow,
/// and a copy when they need masking, sign extension or byte swapping.
final class PixelArray {
  PixelArray(this.values, this.module);

  /// The stored values, before any LUT.
  final List<int> values;

  /// The pixel module the frame was decoded with.
  final PixelModule module;

  /// Rows.
  int get rows => module.rows;

  /// Columns.
  int get columns => module.columns;

  /// Samples per pixel: 1 for grayscale.
  int get samplesPerPixel => module.samplesPerPixel;

  /// Applies the Modality LUT (rescale slope and intercept), then [window],
  /// then MONOCHROME1 inversion, giving 8-bit gray (PRD X-04, X-07).
  DisplayBuffer toDisplay(VoiWindow window) {
    if (samplesPerPixel != 1) {
      throw UnsupportedError(
          'displaying color pixels (${module.photometricInterpretation}) is '
          'not supported yet');
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
  String toString() =>
      'PixelArray($rows × $columns × $samplesPerPixel, ${values.runtimeType})';
}
