import '../vr/vr.dart';

/// One data dictionary entry (PS3.6 §6–8, PS3.7 Annex E).
final class DictionaryEntry {
  const DictionaryEntry(this.vrs, this.vm, this.keyword, this.name,
      {this.retired = false});

  /// The allowed VRs: usually one, several for ambiguous entries such as
  /// `US or SS`, none for the item and delimitation tags.
  final List<Vr> vrs;

  /// The value multiplicity, e.g. `'1'`, `'1-n'`, `'2-2n'`.
  final String vm;

  /// The DICOM keyword, e.g. `'PatientName'`; empty for placeholders.
  final String keyword;

  /// The attribute name, e.g. `"Patient's Name"`.
  final String name;

  /// Whether the standard has retired this attribute.
  final bool retired;
}

/// A dictionary entry for a whole range of tags, such as the repeating
/// groups `(60xx,3000)` or `(0028,04x0)`.
///
/// A tag matches when `tag & mask == match`.
final class RepeaterEntry {
  const RepeaterEntry(this.match, this.mask, this.entry);

  final int match;
  final int mask;
  final DictionaryEntry entry;
}
