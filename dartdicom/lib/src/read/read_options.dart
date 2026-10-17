/// Per-call options for reading (PRD C-09). Immutable and `const`-able;
/// nothing is global (surface §7).
final class ReadOptions {
  const ReadOptions({this.stopBeforePixels = false});

  /// Stop before Pixel Data (7FE0,0010), so a header-only read never touches
  /// the pixels: for list views, and for `DirectorySink`'s path.
  final bool stopBeforePixels;
}
