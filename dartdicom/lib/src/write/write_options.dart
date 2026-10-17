import '../read/inflate.dart';

/// Per-call options for writing (PRD C-11). Immutable and `const`-able;
/// nothing is global (surface §7).
final class WriteOptions {
  const WriteOptions({this.deflateCodec});

  /// Encodes a Deflated dataset. The core's default only decodes, so
  /// writing Deflated needs one: `File.writeAsDicom` supplies
  /// `ZLibDeflateCodec` on native platforms.
  final DeflateCodec? deflateCodec;
}
