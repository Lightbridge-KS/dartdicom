/// A VOI window (PS3.3 C.11.2.1.2): the range of modality values to spread
/// over the display's gray levels, as a center and a width.
final class VoiWindow {
  /// A window of [width] (at least 1) around [center], in modality units
  /// (e.g. Hounsfield units for CT).
  VoiWindow(this.center, this.width) {
    if (width < 1) {
      throw ArgumentError.value(width, 'width', 'must be at least 1');
    }
  }

  /// The window's center, (0028,1050).
  final double center;

  /// The window's width, (0028,1051).
  final double width;

  /// Maps a modality value [x] to a gray level in `0..255` with the linear
  /// function of PS3.3 C.11.2.1.2.1. A width of 1 is a threshold.
  int apply(double x) {
    final c = center - 0.5;
    if (width == 1) return x < c ? 0 : 255;
    final half = (width - 1) / 2;
    if (x <= c - half) return 0;
    if (x > c + half) return 255;
    return (((x - c) / (width - 1) + 0.5) * 255).round().clamp(0, 255);
  }

  @override
  String toString() => 'VoiWindow(center: $center, width: $width)';
}
