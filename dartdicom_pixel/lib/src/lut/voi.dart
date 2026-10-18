import 'dart:math' as math;

import 'package:dartdicom/dartdicom.dart';

import '../errors.dart';
import 'frame_source.dart';
import 'lut_table.dart';

/// How a window maps modality values to gray: VOI LUT Function (0028,1056),
/// PS3.3 C.11.2.1.2 and C.11.2.1.3.
enum VoiFunction {
  /// `LINEAR`, the default: the ramp of C.11.2.1.2.1, width at least 1.
  linear,

  /// `LINEAR_EXACT`: the ramp of C.11.2.1.3.2, any width above 0.
  linearExact,

  /// `SIGMOID`: the curve of C.11.2.1.3.1, any width above 0.
  sigmoid,
}

/// A VOI transform (PS3.3 C.11.2): modality values to the display's 256
/// gray levels. Sealed, so a `switch` covers both kinds.
sealed class Voi {
  const Voi();

  /// The gray level, 0–255, of modality value [x].
  int apply(double x);
}

/// A window: the range of modality values (e.g. Hounsfield units) spread
/// over the gray levels, as a center and a width.
///
/// ```dart
/// frame.toDisplay(VoiWindow(40, 400));                       // linear
/// frame.toDisplay(VoiWindow(40, 400, function: VoiFunction.sigmoid));
/// ```
final class VoiWindow extends Voi {
  /// A window of [width] around [center]. [width] must be at least 1 for
  /// [VoiFunction.linear] and above 0 otherwise; both must be finite.
  VoiWindow(this.center, this.width, {this.function = VoiFunction.linear}) {
    if (!center.isFinite) {
      throw ArgumentError.value(center, 'center', 'must be finite');
    }
    final problem = _widthProblem(width, function);
    if (problem != null) throw ArgumentError.value(width, 'width', problem);
  }

  /// Window Center (0028,1050).
  final double center;

  /// Window Width (0028,1051).
  final double width;

  /// VOI LUT Function (0028,1056).
  final VoiFunction function;

  @override
  int apply(double x) => switch (function) {
        // C.11.2.1.2.1: the center and width shift by half a level.
        VoiFunction.linear => _ramp(x, center - 0.5, width - 1),
        VoiFunction.linearExact => _ramp(x, center, width),
        VoiFunction.sigmoid =>
          (255 / (1 + math.exp(-4 * (x - center) / width))).round(),
      };

  /// Black at or below `c - w/2`, white above `c + w/2`, a ramp between; a
  /// zero `w` (a LINEAR width of 1) is a threshold at `c`.
  static int _ramp(double x, double c, double w) {
    if (x <= c - w / 2) return 0;
    if (x > c + w / 2) return 255;
    return (((x - c) / w + 0.5) * 255).round().clamp(0, 255);
  }

  @override
  String toString() =>
      'VoiWindow(center: $center, width: $width, ${function.name})';
}

/// A VOI LUT Sequence's table: modality values to entries of [bitsPerEntry]
/// bits, scaled to 0–255 by `2^bitsPerEntry − 1`, the range the descriptor
/// declares (no guessing from the entries).
final class VoiLut extends Voi {
  /// A table of [entries] mapping [firstMapped] and the values after it;
  /// [bitsPerEntry] is 8–16.
  VoiLut(
      {required int firstMapped,
      required int bitsPerEntry,
      required List<int> entries})
      : this._(_checked(firstMapped, bitsPerEntry, entries));

  VoiLut._(this._table);

  final LutTable _table;

  /// The modality value that maps to the first entry.
  int get firstMapped => _table.firstMapped;

  /// Bits per entry, from the LUT Descriptor.
  int get bitsPerEntry => _table.bits;

  /// The entries. Unmodifiable.
  List<int> get entries => _table.entries;

  @override
  int apply(double x) {
    final top = (1 << _table.bits) - 1;
    final entry = math.min(_table.lookup(x), top);
    return (entry * 255 / top).round();
  }

  static LutTable _checked(int first, int bits, List<int> entries) {
    if (LutTable.bitsProblem(bits) case final problem?) {
      throw ArgumentError.value(bits, 'bitsPerEntry', problem);
    }
    if (entries.isEmpty) {
      throw ArgumentError.value(entries, 'entries', 'must not be empty');
    }
    return LutTable(first, bits, entries);
  }

  @override
  String toString() =>
      'VoiLut(${entries.length} entries of $bitsPerEntry bits)';
}

/// Frame [frame]'s VOI as [ds] states it, or `null` when it states none:
/// from the frame's Frame VOI LUT functional group, else the top level
/// (blueprint F44).
///
/// A VOI LUT Sequence wins over a window when [preferLut], as pydicom's
/// `apply_voi_lut`. [index] picks the LUT item or the window; a multi-valued
/// Window Center or Width is indexed and a single value kept, as pydicom
/// does. A VOI that is there but invalid is an [InvalidPixelModule], or an
/// [UnsupportedPixelEncoding] for an unknown VOI LUT Function; an [index]
/// past them is a [RangeError].
Voi? datasetVoi(Dataset ds,
    {int frame = 0, int index = 0, bool preferLut = true}) {
  final source = frameSource(ds, frame, DicomTags.frameVoilutSequence);
  final luts = source.attribute(DicomTags.voilutSequence) ?? Sequence(const []);
  // pydicom checks the first item only.
  final hasLut = luts.isNotEmpty &&
      luts.first.contains(DicomTags.lutDescriptor) &&
      luts.first.contains(DicomTags.lutData);
  final centers = _finite(source, DicomTags.windowCenter);
  final widths = _finite(source, DicomTags.windowWidth);
  final hasWindow = centers.isNotEmpty && widths.isNotEmpty;

  if (hasLut && (preferLut || !hasWindow)) {
    RangeError.checkValidIndex(index, luts, 'index');
    return VoiLut._(LutTable.of(luts[index], from: ds));
  }
  if (!hasWindow) return null;
  double pick(List<double> values) {
    if (values.length == 1) return values.single;
    RangeError.checkValidIndex(index, values, 'index');
    return values[index];
  }

  final function = _function(source);
  final width = pick(widths);
  final problem = _widthProblem(width, function);
  if (problem != null) {
    throw InvalidPixelModule(DicomTags.windowWidth, problem);
  }
  return VoiWindow(pick(centers), width, function: function);
}

String? _widthProblem(double width, VoiFunction function) {
  if (!width.isFinite) return 'must be finite';
  return switch (function) {
    VoiFunction.linear when width < 1 => 'must be at least 1 for LINEAR',
    VoiFunction.linearExact ||
    VoiFunction.sigmoid when width <= 0 =>
      'must be above 0 for LINEAR_EXACT and SIGMOID',
    _ => null,
  };
}

VoiFunction _function(Dataset source) =>
    switch (source.attribute(DicomTags.voilutFunction)?.trim().toUpperCase()) {
      null || '' || 'LINEAR' => VoiFunction.linear,
      'LINEAR_EXACT' => VoiFunction.linearExact,
      'SIGMOID' => VoiFunction.sigmoid,
      _ => throw UnsupportedPixelEncoding(
          'is not LINEAR, LINEAR_EXACT or SIGMOID',
          tag: DicomTags.voilutFunction),
    };

List<double> _finite(Dataset ds, Many<double> tag) {
  final values = ds.attributes(tag);
  if (values.any((v) => !v.isFinite)) {
    throw InvalidPixelModule(tag, 'must hold finite numbers');
  }
  return values;
}
