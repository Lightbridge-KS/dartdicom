/// Decode DICOM Pixel Data, apply Modality and VOI LUTs, and produce 8-bit
/// display buffers.
///
/// ```dart
/// final buf = ds.pixels.frame(0).toDisplay(); // the frame's own VOI
/// ```
library;

export 'src/display/display_buffer.dart';
export 'src/errors.dart'
    show InvalidPixelModule, PixelDataException, UnsupportedPixelEncoding;
export 'src/lut/voi.dart' show Voi, VoiFunction, VoiLut, VoiWindow;
export 'src/pixel_array/pixel_array.dart';
export 'src/pixel_array/pixel_module.dart';
export 'src/pixels.dart';
