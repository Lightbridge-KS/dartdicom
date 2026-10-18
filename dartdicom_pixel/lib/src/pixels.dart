import 'package:dartdicom/dartdicom.dart';

import 'decode/native.dart';
import 'errors.dart';
import 'lut/voi_window.dart';
import 'pixel_array/pixel_array.dart';
import 'pixel_array/pixel_module.dart';

/// Pixel access on a [Dataset] (PRD X-03). The core holds no pixel code;
/// this package adds it as an extension (blueprint F4).
extension DatasetPixels on Dataset {
  /// The dataset's Pixel Data, decoded one frame at a time. Throws an
  /// [InvalidPixelModule] if the Image Pixel module is missing or invalid.
  PixelData get pixels => PixelData(this);

  /// The VOI window to display [frame] with: the first Window Center and
  /// Width if the dataset has them, otherwise the full range of the frame's
  /// modality values, ignoring the Pixel Padding Value.
  VoiWindow voiWindow({int frame = 0}) {
    final centers = _finite(this, DicomTags.windowCenter);
    final widths = _finite(this, DicomTags.windowWidth);
    if (centers.isNotEmpty && widths.isNotEmpty && widths.first >= 1) {
      return VoiWindow(centers.first, widths.first);
    }
    final range = pixels.frame(frame).modalityRange() ?? (0.0, 0.0);
    final (lo, hi) = range;
    // The window whose linear ramp runs from exactly lo to hi.
    return VoiWindow((lo + hi) / 2 + 0.5, hi - lo + 1);
  }
}

/// A dataset's Pixel Data: its frames, decoded on demand.
final class PixelData {
  PixelData(this._dataset) : module = PixelModule.of(_dataset);

  final Dataset _dataset;

  /// The pixel module attributes the frames are decoded with.
  final PixelModule module;

  /// The number of frames.
  int get numberOfFrames => module.numberOfFrames;

  /// Decodes frame [index] (0-based). Throws an [UnsupportedPixelEncoding]
  /// for an encoding this version can't decode yet (compressed, Bits
  /// Allocated other than 1, 8, 16 or 32, YBR_FULL_422), an
  /// [InvalidPixelModule] if Pixel Data doesn't hold the frame, and a
  /// [RangeError] for an index out of range.
  PixelArray frame(int index) => decodeNative(_dataset, module, index, 1);

  /// Decodes every frame into one buffer, as pydicom's `pixel_array` does;
  /// `.frame(i)` of the result views one without decoding again. Throws as
  /// [frame] does.
  PixelArray allFrames() =>
      decodeNative(_dataset, module, 0, module.numberOfFrames);
}

/// [tag]'s values; NaN or an infinity is an [InvalidPixelModule].
List<double> _finite(Dataset ds, Many<double> tag) {
  final List<double> values;
  try {
    values = ds.getAll(tag);
  } on DicomDataException {
    throw InvalidPixelModule(tag, 'cannot be read as its VR');
  }
  if (values.any((v) => !v.isFinite)) {
    throw InvalidPixelModule(tag, 'must hold finite numbers');
  }
  return values;
}
