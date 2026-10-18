import 'package:dartdicom/dartdicom.dart';

import 'decode/native.dart';
import 'errors.dart';
import 'lut/voi.dart';
import 'pixel_array/pixel_array.dart';
import 'pixel_array/pixel_module.dart';

/// Pixel access on a [Dataset] (PRD X-03). The core holds no pixel code;
/// this package adds it as an extension (blueprint F4).
extension DatasetPixels on Dataset {
  /// The dataset's Pixel Data, decoded one frame at a time. Throws an
  /// [InvalidPixelModule] if the Image Pixel module is missing or invalid.
  PixelData get pixels => PixelData(this);

  /// Frame [frame]'s VOI as this dataset states it (surface S11): a
  /// [VoiLut] from the VOI LUT Sequence, or a [VoiWindow] from Window Center
  /// and Width with its VOI LUT Function, from the frame's functional groups
  /// when it has them; `null` when there is none. A VOI LUT wins when
  /// [preferLut], as pydicom's `apply_voi_lut`; [index] picks among several.
  ///
  /// Throws an [InvalidPixelModule] for a VOI that is there but invalid, an
  /// [UnsupportedPixelEncoding] for an unknown VOI LUT Function, and a
  /// [RangeError] for an [index] past them.
  Voi? voi({int frame = 0, int index = 0, bool preferLut = true}) =>
      datasetVoi(this, frame: frame, index: index, preferLut: preferLut);
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
