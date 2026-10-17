import 'dart:math';

/// A DICOM unique identifier (PS3.5 §9), e.g. a SOP Class or a Transfer
/// Syntax. At runtime it is its `String`.
extension type const Uid(String value) implements Object {
  /// A new, globally unique UID (PRD C-16, surface S10).
  ///
  /// By default `2.25.` followed by a random UUID (version 4) as a decimal
  /// integer (PS3.5 §B.2), which needs no registered root. With [prefix], an
  /// organization's root such as `'1.2.840.99999'` (no trailing dot), it is
  /// the prefix, a dot, then random digits up to 64 characters in all.
  ///
  /// Throws an [ArgumentError] if [prefix] isn't a valid UID with room for
  /// a suffix (at most 62 characters).
  static Uid generate({String? prefix}) {
    final random = Random.secure();
    if (prefix == null) {
      final bytes = [for (var i = 0; i < 16; i++) random.nextInt(256)];
      bytes[6] = bytes[6] & 0x0F | 0x40; // version 4
      bytes[8] = bytes[8] & 0x3F | 0x80; // RFC 4122 variant
      var n = BigInt.zero;
      for (final b in bytes) {
        n = n << 8 | BigInt.from(b);
      }
      return Uid('2.25.$n');
    }
    if (!Uid(prefix).isValid || prefix.length > 62) {
      throw ArgumentError.value(prefix, 'prefix',
          'must be a valid UID of at most 62 characters, without a trailing dot');
    }
    final digits = 64 - prefix.length - 1;
    final suffix = StringBuffer()..write(1 + random.nextInt(9));
    for (var i = 1; i < digits; i++) {
      suffix.write(random.nextInt(10));
    }
    return Uid('$prefix.$suffix');
  }

  /// Whether this is a valid UID (PS3.5 §9.1): 1–64 characters, numeric
  /// components separated by dots, no component with a leading zero.
  ///
  /// Reading never enforces it: real files carry invalid UIDs.
  bool get isValid =>
      value.isNotEmpty &&
      value.length <= 64 &&
      RegExp(r'^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))*$').hasMatch(value);
}
