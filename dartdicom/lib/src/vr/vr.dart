// The DICOM codes themselves are the names: they are what every DICOM reader
// already knows, and lowercase would collide with the reserved word `is`.
// ignore_for_file: constant_identifier_names

/// A Value Representation: the encoding type of an element's value
/// (PS3.5 §6.2).
enum Vr {
  AE,
  AS,
  AT,
  CS,
  DA,
  DS,
  DT,
  FD,
  FL,
  IS,
  LO,
  LT,
  OB,
  OD,
  OF,
  OL,
  OV,
  OW,
  PN,
  SH,
  SL,
  SQ,
  SS,
  ST,
  SV,
  TM,
  UC,
  UI,
  UL,
  UN,
  UR,
  US,
  UT,
  UV;

  /// The two-letter code, e.g. `'PN'`.
  String get code => name;

  /// Whether Explicit VR encodings use the 4-byte length form
  /// (PS3.5 §7.1.2).
  bool get hasLongLength => switch (this) {
        OB ||
        OD ||
        OF ||
        OL ||
        OV ||
        OW ||
        SQ ||
        SV ||
        UC ||
        UN ||
        UR ||
        UT ||
        UV =>
          true,
        _ => false,
      };

  /// The VR for a two-letter [code], or `null` if there is none.
  static Vr? fromCode(String code) {
    for (final vr in values) {
      if (vr.name == code) return vr;
    }
    return null;
  }
}
