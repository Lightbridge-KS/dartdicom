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

/// Decoded pixels: the stored values of one or more frames, plus their
/// shape (PRD X-01).
///
/// [values] is a typed list ([Int16List], [Uint16List], [Uint8List], …)
/// in C order: frame, row, column, sample, with samples interleaved. It is
/// a zero-copy view of Pixel Data where the bytes allow, and a copy when
/// they need unpacking, masking, sign extension, byte swapping or
/// interleaving. Either way it is unmodifiable: a view shares the dataset's
/// bytes, so an edit would reach a written file as "untouched" data. Copy
/// it first (`Int16List.fromList(values)`) to change it.
final class PixelArray {
  /// [values] (a typed list of [module]'s dtype) as whole frames, the first
  /// of them frame [firstFrame] of its dataset.
  PixelArray(List<int> values, this.module, {this.firstFrame = 0})
      : dtype = PixelDtype.of(module),
        _data = values,
        values = _unmodifiable(values) {
    final perFrame = module.samplesPerFrame;
    if (values.isEmpty || values.length % perFrame != 0) {
      throw ArgumentError.value(
          values.length, 'values', 'must hold whole frames of the module');
    }
  }

  /// The stored values, before any LUT. Unmodifiable.
  final List<int> values;

  /// The same values, as given; the LUT loops read these.
  final List<int> _data;

  /// The pixel module the frames were decoded with.
  final PixelModule module;

  /// The Dart type of [values].
  final PixelDtype dtype;

  /// The index, in its dataset, of this array's first frame.
  final int firstFrame;

  /// (frames, rows, columns, samples).
  PixelShape get shape => (
        frames: values.length ~/ module.samplesPerFrame,
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

  /// Frame [index] of this array (0-based, counted from [firstFrame]): a
  /// view sharing its values, so nothing is decoded or copied.
  PixelArray frame(int index) {
    final frames = shape.frames;
    if (index < 0 || index >= frames) {
      throw RangeError.range(index, 0, frames - 1, 'index');
    }
    final length = module.samplesPerFrame;
    return PixelArray(
        _view(_data, index * length, (index + 1) * length), module,
        firstFrame: firstFrame + index);
  }

  /// Applies the Modality LUT (rescale slope and intercept), then [window],
  /// then MONOCHROME1 inversion, giving 8-bit gray (PRD X-04, X-07).
  ///
  /// Throws an [UnsupportedPixelEncoding] for anything but MONOCHROME1 and
  /// MONOCHROME2: color and palette display is X-08. A buffer is one frame,
  /// so an array of several throws a [StateError]: display `.frame(i)`.
  DisplayBuffer toDisplay(VoiWindow window) {
    _oneFrame('toDisplay');
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
    final gray = Uint8List(_data.length);
    for (var i = 0; i < _data.length; i++) {
      final level = window.apply(_data[i] * slope + intercept);
      gray[i] = invert ? 255 - level : level;
    }
    return DisplayBuffer(columns, rows, gray);
  }

  /// The smallest and largest modality values, ignoring the Pixel Padding
  /// Value, or `null` if every pixel is padding.
  (double, double)? modalityRange() {
    _oneFrame('modalityRange');
    final padding = module.pixelPaddingValue;
    int? lo;
    int? hi;
    for (final v in _data) {
      if (v == padding) continue;
      if (lo == null || v < lo) lo = v;
      if (hi == null || v > hi) hi = v;
    }
    if (lo == null || hi == null) return null;
    final a = lo * module.rescaleSlope + module.rescaleIntercept;
    final b = hi * module.rescaleSlope + module.rescaleIntercept;
    return a <= b ? (a, b) : (b, a);
  }

  void _oneFrame(String method) {
    if (shape.frames != 1) {
      throw StateError('$method works on one frame; this array holds '
          '${shape.frames}: use .frame(i)');
    }
  }

  @override
  String toString() {
    final (:frames, :rows, :columns, :samples) = shape;
    return 'PixelArray($frames × $rows × $columns × $samples, ${dtype.name})';
  }
}

/// [list]'s values from [start] to [end], sharing its buffer.
List<int> _view(List<int> list, int start, int end) => switch (list) {
      Int8List() => Int8List.sublistView(list, start, end),
      Uint8List() => Uint8List.sublistView(list, start, end),
      Int16List() => Int16List.sublistView(list, start, end),
      Uint16List() => Uint16List.sublistView(list, start, end),
      Int32List() => Int32List.sublistView(list, start, end),
      Uint32List() => Uint32List.sublistView(list, start, end),
      _ => list.sublist(start, end),
    };

/// [list] as an unmodifiable view of the same type.
List<int> _unmodifiable(List<int> list) => switch (list) {
      Int8List() => list.asUnmodifiableView(),
      Uint8List() => list.asUnmodifiableView(),
      Int16List() => list.asUnmodifiableView(),
      Uint16List() => list.asUnmodifiableView(),
      Int32List() => list.asUnmodifiableView(),
      Uint32List() => list.asUnmodifiableView(),
      _ => List.unmodifiable(list),
    };
