import 'package:dartdicom/dartdicom.dart';

import 'decode/native.dart';
import 'lut/voi_window.dart';
import 'pixel_array/pixel_array.dart';
import 'pixel_array/pixel_module.dart';

/// Pixel access on a [Dataset] (PRD X-03). The core holds no pixel code;
/// this package adds it as an extension (blueprint F4).
extension DatasetPixels on Dataset {
  /// The dataset's Pixel Data, decoded one frame at a time.
  PixelData get pixels => PixelData(this);

  /// The VOI window to display [frame] with: the first Window Center and
  /// Width if the dataset has them, otherwise the full range of the frame's
  /// modality values, ignoring the Pixel Padding Value.
  VoiWindow voiWindow({int frame = 0}) {
    final centers = getAll(DicomTags.windowCenter);
    final widths = getAll(DicomTags.windowWidth);
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

  /// Decodes frame [index] (0-based). Throws an `UnsupportedError` for an
  /// encoding this version can't decode yet (compressed, or Bits Allocated
  /// other than 8 or 16).
  PixelArray frame(int index) => decodeNativeFrame(_dataset, module, index);
}
