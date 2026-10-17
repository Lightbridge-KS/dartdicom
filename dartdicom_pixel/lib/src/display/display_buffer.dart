import 'dart:typed_data';

/// An 8-bit image ready for the screen: one gray byte per pixel, row by row,
/// after the Modality and VOI LUTs (PRD X-07).
///
/// ```dart
/// final buf = ds.pixels.frame(0).toDisplay(ds.voiWindow());
/// // Flutter: ui.decodeImageFromPixels(buf.toRgba(), buf.width, ...)
/// ```
final class DisplayBuffer {
  /// A [width] × [height] image of [gray] levels.
  DisplayBuffer(this.width, this.height, this.gray) {
    if (gray.length != width * height) {
      throw ArgumentError.value(
          gray.length, 'gray', 'must hold width × height bytes');
    }
  }

  /// Columns.
  final int width;

  /// Rows.
  final int height;

  /// One byte per pixel, 0 = black, row by row.
  final Uint8List gray;

  /// The same image as RGBA, 4 bytes per pixel with alpha 255, e.g. for
  /// Flutter's `decodeImageFromPixels`. Allocates a new buffer each call.
  Uint8List toRgba() {
    final rgba = Uint8List(gray.length * 4);
    for (var i = 0; i < gray.length; i++) {
      final g = gray[i];
      rgba
        ..[i * 4] = g
        ..[i * 4 + 1] = g
        ..[i * 4 + 2] = g
        ..[i * 4 + 3] = 255;
    }
    return rgba;
  }

  @override
  String toString() => 'DisplayBuffer($width × $height)';
}
