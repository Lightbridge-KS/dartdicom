import 'uid.dart';
import 'uids.g.dart';

/// How a transfer syntax encodes a dataset (PS3.5 §10): the facts the
/// reader and the writer both need.
///
/// Look one up with [TransferSyntax.of]; the UID constants themselves are
/// in `TransferSyntaxes`.
final class TransferSyntax {
  const TransferSyntax._(
    this.uid, {
    required this.explicitVr,
    required this.littleEndian,
    this.deflated = false,
    this.encapsulated = false,
  });

  /// Implicit VR Little Endian, the DICOM default.
  static const implicitVrLittleEndian = TransferSyntax._(
      TransferSyntaxes.implicitVrLittleEndian,
      explicitVr: false,
      littleEndian: true);

  /// Explicit VR Little Endian.
  static const explicitVrLittleEndian = TransferSyntax._(
      TransferSyntaxes.explicitVrLittleEndian,
      explicitVr: true,
      littleEndian: true);

  /// Deflated Explicit VR Little Endian.
  static const deflatedExplicitVrLittleEndian = TransferSyntax._(
      TransferSyntaxes.deflatedExplicitVrLittleEndian,
      explicitVr: true,
      littleEndian: true,
      deflated: true);

  /// Explicit VR Big Endian (retired; read-only, PRD C-08).
  static const explicitVrBigEndian = TransferSyntax._(
      TransferSyntaxes.explicitVrBigEndian,
      explicitVr: true,
      littleEndian: false);

  /// The descriptor for [uid]. Any other transfer syntax in the standard's
  /// registry is a compressed one: Explicit VR Little Endian with
  /// encapsulated Pixel Data. Returns `null` for a UID the registry
  /// doesn't list.
  static TransferSyntax? of(Uid uid) {
    for (final ts in _native) {
      if (ts.uid == uid) return ts;
    }
    if (!TransferSyntaxes.all.contains(uid)) return null;
    return TransferSyntax._(uid,
        explicitVr: true, littleEndian: true, encapsulated: true);
  }

  static const _native = [
    implicitVrLittleEndian,
    explicitVrLittleEndian,
    deflatedExplicitVrLittleEndian,
    explicitVrBigEndian,
  ];

  /// The transfer syntax UID.
  final Uid uid;

  /// Whether each element carries its VR.
  final bool explicitVr;

  /// The byte order of binary values.
  final bool littleEndian;

  /// Whether the dataset is deflated (zlib, PS3.5 §A.5).
  final bool deflated;

  /// Whether Pixel Data is encapsulated (compressed frames in fragments).
  final bool encapsulated;

  @override
  bool operator ==(Object other) => other is TransferSyntax && other.uid == uid;

  @override
  int get hashCode => uid.hashCode;

  @override
  String toString() => 'TransferSyntax(${uid.value})';
}
