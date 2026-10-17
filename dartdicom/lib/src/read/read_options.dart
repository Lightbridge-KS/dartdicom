import 'inflate.dart';

/// Per-call options for reading (PRD C-09). Immutable and `const`-able;
/// nothing is global (surface §7).
final class ReadOptions {
  const ReadOptions(
      {this.stopBeforePixels = false, this.deferSize, this.deflateCodec});

  /// Stop before Pixel Data (7FE0,0010), so a header-only read never touches
  /// the pixels: for list views, and for `DirectorySink`'s path.
  final bool stopBeforePixels;

  /// Values longer than this many bytes are not read until first accessed
  /// (deferred), when the source can be read again (a file; not memory).
  /// Top-level values only; sequences and (0008,0005) are never deferred.
  /// `null` (the default) reads everything.
  final int? deferSize;

  /// Decodes a Deflated dataset; `null` uses the pure-Dart inflate, which
  /// works on every platform.
  final DeflateCodec? deflateCodec;
}
