import '../tag/tag.dart';
import 'dictionary.g.dart';
import 'dictionary_entry.dart';

/// The data dictionary: tag → VR, VM, keyword, name and retired flag
/// (PS3.6 data elements and PS3.7 command elements, PRD C-02).
///
/// An immutable value, never a global registry (blueprint F11). Private
/// entries will come through `withPrivate`, passed in per read.
final class Dictionary {
  const Dictionary._();

  /// The standard dictionary, generated from the pinned DICOM release.
  static const standard = Dictionary._();

  /// The entry for [tag], including repeating groups such as `(60xx,3000)`,
  /// or `null` if the standard doesn't define it.
  DictionaryEntry? entry(Tag tag) {
    final exact = standardEntries[tag.value];
    if (exact != null) return exact;
    for (final repeater in repeaterEntries) {
      if (tag.value & repeater.mask == repeater.match) return repeater.entry;
    }
    return null;
  }
}

/// `(0010,0010) PatientName`: a tag as exception messages name it. Never
/// carries a value (I-9).
String describeTag(Tag tag) {
  String hex(int n) => n.toRadixString(16).padLeft(4, '0').toUpperCase();
  final label = '(${hex(tag.group)},${hex(tag.element)})';
  final keyword = Dictionary.standard.entry(tag)?.keyword ?? '';
  return keyword.isEmpty ? label : '$label $keyword';
}
