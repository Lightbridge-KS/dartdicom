import '../tag/tag.dart';
import 'inflate.dart';

/// Per-call options for reading (PRD C-09). Immutable and `const`-able;
/// nothing is global (surface §7).
final class ReadOptions {
  const ReadOptions(
      {this.stopBeforePixels = false,
      this.deferSize,
      this.tags,
      this.force = false,
      this.deflateCodec});

  /// Stop before Pixel Data (7FE0,0010), so a header-only read never touches
  /// the pixels: for list views, and for `DirectorySink`'s path.
  final bool stopBeforePixels;

  /// Values longer than this many bytes are not read until first accessed
  /// (deferred), when the source can be read again (a file; not memory).
  /// Top-level values only; sequences and (0008,0005) are never deferred.
  /// `null` (the default) reads everything.
  final int? deferSize;

  /// Read only these top-level elements, and (0008,0005), which decodes
  /// them; `null` (the default) reads all. Sequence items are read whole.
  /// A file read this way is partial: writing it is refused.
  final Set<Tag>? tags;

  /// Read data that isn't a Part 10 file: no preamble or `DICM`, file meta
  /// at offset 0 if any, else a bare dataset whose transfer syntax is
  /// detected from the bytes. Each such repair is in the read report.
  final bool force;

  /// Decodes a Deflated dataset; `null` uses the pure-Dart inflate, which
  /// works on every platform.
  final DeflateCodec? deflateCodec;
}
