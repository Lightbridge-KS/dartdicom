import 'package:dartdicom/dartdicom.dart';

import '../errors.dart';
import 'frame_source.dart';
import 'lut_table.dart';

/// A frame's Modality LUT (PS3.3 C.11.1): stored values to modality values,
/// such as Hounsfield units. Either a [Rescale] or a [ModalityLutTable].
sealed class ModalityLut {
  const ModalityLut();

  /// Frame [frame]'s Modality LUT: from its Pixel Value Transformation
  /// functional group if it has one, else the top level (blueprint F44). A
  /// Modality LUT Sequence wins over a rescale; a rescale needs both Slope
  /// and Intercept, as in pydicom; neither is the identity.
  factory ModalityLut.of(Dataset ds, int frame) {
    final source =
        frameSource(ds, frame, DicomTags.pixelValueTransformationSequence);
    final table = source.attribute(DicomTags.modalityLutSequence);
    if (table != null && table.isNotEmpty) {
      final ts = ds.transferSyntax;
      final littleEndian =
          ts == null || (TransferSyntax.of(ts)?.littleEndian ?? true);
      return ModalityLutTable(
          LutTable.of(table.first, littleEndian: littleEndian));
    }
    final slope = _finite(source, DicomTags.rescaleSlope);
    final intercept = _finite(source, DicomTags.rescaleIntercept);
    return slope != null && intercept != null
        ? Rescale(slope, intercept)
        : const Rescale(1, 0);
  }

  /// The modality value of stored value [stored].
  double apply(int stored);
}

/// `stored × slope + intercept`, in that order, as numpy computes it, so
/// the result is bit-identical to pydicom's.
final class Rescale extends ModalityLut {
  const Rescale(this.slope, this.intercept);

  final double slope;
  final double intercept;

  @override
  double apply(int stored) => stored * slope + intercept;
}

/// A Modality LUT Sequence's table.
final class ModalityLutTable extends ModalityLut {
  const ModalityLutTable(this.table);

  final LutTable table;

  @override
  double apply(int stored) => table.lookup(stored.toDouble()).toDouble();
}

double? _finite(Dataset ds, One<double> tag) {
  final value = ds.attribute(tag);
  if (value != null && !value.isFinite) {
    throw InvalidPixelModule(tag, 'must be a finite number');
  }
  return value;
}
