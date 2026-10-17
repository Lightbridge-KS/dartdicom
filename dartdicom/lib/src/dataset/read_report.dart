import '../dictionary/dictionary.dart';
import '../tag/tag.dart';

/// What lenient reading repaired in real-world data (PRD C-10): every repair
/// is reported, never silent. Holds tags and offsets, never values (I-9).
final class ReadReport {
  /// A report of [repairs].
  ReadReport(Iterable<Repair> repairs) : repairs = List.unmodifiable(repairs);

  /// A clean report: the data needed no repair.
  ReadReport.clean() : repairs = const [];

  /// Each repair, in the order the data was read.
  final List<Repair> repairs;

  /// Whether the data was read as written, with nothing repaired.
  bool get isClean => repairs.isEmpty;

  /// One line: `clean`, or how many repairs of which kinds, e.g.
  /// `2 repairs: unReplaced ×1, truncated ×1`.
  String summary() {
    if (isClean) return 'clean';
    final counts = <RepairKind, int>{};
    for (final r in repairs) {
      counts[r.kind] = (counts[r.kind] ?? 0) + 1;
    }
    final kinds =
        counts.entries.map((e) => '${e.key.name} ×${e.value}').join(', ');
    return '${repairs.length} repair${repairs.length == 1 ? '' : 's'}: $kinds';
  }

  @override
  String toString() => 'ReadReport(${summary()})';
}

/// One repair: what was wrong, and where.
final class Repair {
  const Repair(this.kind, {this.tag, this.offset});

  final RepairKind kind;

  /// The element it concerns, if one.
  final Tag? tag;

  /// Where in the input, if known.
  final int? offset;

  @override
  String toString() => '${kind.name}'
      '${tag == null ? '' : ' at ${describeTag(tag!)}'}'
      '${offset == null ? '' : ' (byte $offset)'}: ${kind.description}';
}

/// The kinds of repair lenient reading makes. They follow pydicom 3.0.2's
/// behavior, the oracle; where they differ, the dartdoc says why.
enum RepairKind {
  /// No preamble and `DICM`: read with `ReadOptions(force: true)`.
  noPreamble('no preamble or DICM prefix; read because force was set'),

  /// No file meta: read as a bare dataset.
  noFileMeta('no file meta; read as a bare dataset'),

  /// No (0002,0010): the syntax was detected from the data.
  syntaxDetected('no transfer syntax declared; detected from the data'),

  /// The data contradicts the declared syntax (explicit vs implicit VR),
  /// in a dataset or an item: it was read as the data shows.
  syntaxContradicted(
      'the data contradicts the declared transfer syntax; read as the data '
      'shows'),

  /// In an Explicit VR dataset, an element whose VR bytes aren't letters:
  /// read as Implicit VR.
  implicitElement(
      'an element with no VR in Explicit VR data; read as implicit'),

  /// A VR code that isn't one: read as UN.
  unknownVr('an unknown VR code; read as UN'),

  /// Explicit UN with an undefined length: read as an SQ of Implicit VR
  /// items (PS3.5 §6.2.2), and written as SQ.
  unSequence('UN with an undefined length; read as a sequence'),

  /// UN whose real VR the dictionary knows: given that VR, as pydicom's
  /// `replace_un_with_known_vr` does.
  unReplaced('UN where the dictionary knows the VR; the dictionary VR is used'),

  /// A numeric value whose length isn't a multiple of its size: the whole
  /// values are kept. pydicom throws on access.
  wrongLength('a value length that does not fit its VR; the partial value is '
      'dropped'),

  /// Several values in an element the dictionary allows one (DA1): `get`
  /// returns the first.
  multipleValues('several values where the dictionary allows one'),

  /// A group length that doesn't match its group: it is dropped on write.
  staleGroupLength('a group length that does not match its group; dropped on '
      'write'),

  /// The data ends inside an element or item: the dataset holds what came
  /// before (a partial read; writing it is refused).
  truncated('the data ends early; the dataset holds what came before'),

  /// An undefined-length value with no end before the data ends: dropped,
  /// as pydicom drops it.
  valueDropped('an undefined-length value runs past the end; dropped'),

  /// Fewer bytes than an element header after the last element: ignored.
  trailingBytes('bytes after the last element; ignored');

  const RepairKind(this.description);

  /// What happened, in a sentence fragment.
  final String description;
}
