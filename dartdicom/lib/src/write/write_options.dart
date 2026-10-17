import '../read/inflate.dart';
import '../uid/uid.dart';

/// Per-call options for writing (PRD C-11). Immutable and `const`-able;
/// nothing is global (surface §7).
final class WriteOptions {
  const WriteOptions({this.transferSyntax, this.deflateCodec});

  /// The transfer syntax to write in; `null` keeps the one the file was
  /// read in (surface §7). Big Endian is read-only and refused (C-08).
  final Uid? transferSyntax;

  /// Encodes a Deflated dataset. The core's default only decodes, so
  /// writing Deflated needs one: `File.writeAsDicom` supplies
  /// `ZLibDeflateCodec` on native platforms.
  final DeflateCodec? deflateCodec;
}
