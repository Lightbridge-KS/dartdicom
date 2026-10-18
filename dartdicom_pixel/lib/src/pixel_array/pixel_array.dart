import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';

import '../display/display_buffer.dart';
import '../display/gray.dart';
import '../errors.dart';
import '../lut/modality_lut.dart';
import '../lut/voi.dart';
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
  /// of them frame [firstFrame] of [dataset]. Each frame's Modality LUT and
  /// VOI come from [dataset]; without one, the Modality LUT is the identity.
  PixelArray(List<int> values, this.module, {this.firstFrame = 0, this.dataset})
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

  /// The dataset the frames come from, for their Modality LUT and VOI.
  final Dataset? dataset;

  /// Each frame's Modality LUT, resolved on first use.
  late final List<ModalityLut> _modality = [
    for (var f = 0; f < shape.frames; f++)
      switch (dataset) {
        final ds? => ModalityLut.of(ds, firstFrame + f),
        null => const Rescale(1, 0),
      },
  ];

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
        firstFrame: firstFrame + index, dataset: dataset);
  }

  /// The Modality LUT applied to every value (PRD X-04): modality values,
  /// such as Hounsfield units for CT, frame by frame from each frame's own
  /// rescale or Modality LUT Sequence, functional groups included. Equal,
  /// bit for bit, to pydicom's `apply_modality_lut`. Allocates 8 bytes per
  /// value.
  Float64List toModality() {
    final out = Float64List(_data.length);
    final length = module.samplesPerFrame;
    for (var f = 0; f < _modality.length; f++) {
      final lut = _modality[f];
      for (var i = f * length; i < (f + 1) * length; i++) {
        out[i] = lut.apply(_data[i]);
      }
    }
    return out;
  }

  /// The frame as 8-bit gray (PRD X-04, X-07): its Modality LUT, then
  /// [voi], then MONOCHROME1's inversion.
  ///
  /// With no [voi], the frame's own (blueprint F45): its dataset's VOI LUT
  /// or window for this frame, functional groups included, else
  /// [autoWindow]. Pass a [VoiWindow] to window it yourself, e.g. while the
  /// user drags; the decode isn't repeated.
  ///
  /// Throws an [UnsupportedPixelEncoding] for anything but MONOCHROME1 and
  /// MONOCHROME2: color and palette display is X-08. A buffer is one frame,
  /// so an array of several throws a [StateError]: display `.frame(i)`.
  DisplayBuffer toDisplay([Voi? voi]) {
    _oneFrame('toDisplay');
    if (!module.isMonochrome) {
      throw UnsupportedPixelEncoding(
          'is not MONOCHROME1 or MONOCHROME2: displaying color or palette '
          'images is not supported yet (X-08); the decoded values are in '
          '`values`',
          tag: DicomTags.photometricInterpretation);
    }
    if (samplesPerPixel != 1) {
      // PS3.3 C.7.6.3.1.2: MONOCHROME1 and MONOCHROME2 have one sample.
      throw InvalidPixelModule(DicomTags.samplesPerPixel,
          'must be 1 for MONOCHROME1 and MONOCHROME2');
    }
    final own = switch (dataset) {
      final ds? when voi == null => datasetVoi(ds, frame: firstFrame),
      _ => voi,
    };
    final gray = toGray(_data,
        modality: _modality.single,
        voi: own ?? autoWindow(),
        invert: module.photometricInterpretation == 'MONOCHROME1',
        bitsStored: module.bitsAllocated == 1 ? 1 : module.bitsStored,
        signed: dtype.signed);
    return DisplayBuffer(columns, rows, gray);
  }

  /// The window that spans the frame's own modality values, ignoring the
  /// Pixel Padding Value: what [toDisplay] uses when the dataset states no
  /// VOI, and a starting point for a window the user drags.
  VoiWindow autoWindow() {
    final (lo, hi) = modalityRange() ?? (0.0, 0.0);
    if (!lo.isFinite || !hi.isFinite) {
      // A finite slope can still carry a stored value past a double's range.
      throw InvalidPixelModule(DicomTags.rescaleSlope,
          "takes modality values past a double's range");
    }
    // The LINEAR window whose ramp runs from exactly lo to hi.
    return VoiWindow((lo + hi) / 2 + 0.5, hi - lo + 1);
  }

  /// The smallest and largest modality values, ignoring the Pixel Padding
  /// Value, or `null` if every pixel is padding.
  (double, double)? modalityRange() {
    _oneFrame('modalityRange');
    final padding = module.pixelPaddingValue;
    final modality = _modality.single;
    double? lo;
    double? hi;
    for (final v in _data) {
      if (v == padding) continue;
      final m = modality.apply(v);
      if (lo == null || m < lo) lo = m;
      if (hi == null || m > hi) hi = m;
    }
    return lo == null || hi == null ? null : (lo, hi);
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
