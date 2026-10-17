import 'dart:collection';
import 'dart:typed_data';

import '../dictionary/dictionary.dart';
import '../errors.dart';
import '../tag/tag.dart';
import '../tag/tags.g.dart';
import '../tag/typed_tag.dart';
import '../uid/uid.dart';
import '../vr/ambiguous.dart';
import '../vr/value_codec.dart';
import '../vr/vr.dart';
import 'element.dart';
import 'sequence.dart';

/// A DICOM dataset: data elements kept in ascending tag order (C-06).
///
/// Reads are typed by the tag (data architecture DA1): a [One] tag reads
/// with [get] or [require], a [Many] tag with [getAll], and a wrong read
/// doesn't compile. The default [toString] never shows values (I-9).
///
/// ```dart
/// final String? name = ds.get(DicomTags.patientName);
/// final List<double> centers = ds.getAll(DicomTags.windowCenter);
/// ds.set(DicomTags.patientName, 'Anonymous');
/// ```
final class Dataset {
  /// An empty dataset, to fill with [set] (e.g. a C-FIND query).
  Dataset() : transferSyntax = null;

  Dataset._read(Iterable<DataElement> elements, this.transferSyntax) {
    for (final e in elements) {
      _elements[e.tag.value] = e;
    }
  }

  /// The transfer syntax this dataset was read in, or `null` if it was
  /// built in memory. Binary values not yet re-encoded (such as Pixel
  /// Data bytes) are in its byte order.
  final Uid? transferSyntax;

  final _elements = SplayTreeMap<int, DataElement>();
  var _modified = false;

  /// The number of elements at this level (not counting sequence items).
  int get length => _elements.length;

  /// Whether the dataset has no elements.
  bool get isEmpty => _elements.isEmpty;

  /// Whether an element with [tag] is present (even with an empty value).
  bool contains(Tag tag) => _elements.containsKey(tag.value);

  /// The elements, in ascending tag order.
  Iterable<DataElement> get elements => _elements.values;

  /// The value of [tag], or `null` if it is absent or empty.
  ///
  /// If non-conformant data holds several values for a single-valued tag,
  /// this returns the first.
  T? get<T extends Object>(One<T> tag) {
    final element = _elements[tag.value];
    if (element == null) return null;
    final value = element.value;
    if (value is Uint8List || value is Sequence) {
      if (value is T) return value;
    } else if (value is List) {
      if (value.isEmpty) return null;
      final first = value.first;
      if (first is T) return first;
    }
    throw _wrongType(element, T);
  }

  /// The value of [tag]; throws a [MissingElementException] naming the tag
  /// if it is absent or empty.
  T require<T extends Object>(One<T> tag) =>
      get(tag) ?? (throw MissingElementException(tag));

  /// Every value of [tag], or an empty list if it is absent or empty.
  List<T> getAll<T extends Object>(Many<T> tag) {
    final element = _elements[tag.value];
    if (element == null) return const [];
    final value = element.value;
    if (value is List<T> && value is! Uint8List) return value;
    if (value is List && value.isEmpty) return const [];
    throw _wrongType(element, T);
  }

  /// Sets [tag] to the single [value].
  void set<T extends Object>(One<T> tag, T value) => _put(
      tag,
      value is Uint8List || value is Sequence
          ? value
          : List<T>.unmodifiable([value]));

  /// Sets [tag] to [values], in order.
  void setAll<T extends Object>(Many<T> tag, List<T> values) =>
      _put(tag, List<T>.unmodifiable(values));

  /// Sets [tag] to a zero-length value: a Type 2 attribute that is present
  /// but empty, or a C-FIND return key (surface S3).
  void setEmpty(Tag tag) {
    final vr = _vrFor(tag);
    _put(
        tag,
        switch (vr) {
          Vr.SQ => Sequence(const []),
          _ when isBytesVr(vr) => Uint8List(0),
          _ => const <Never>[],
        });
  }

  /// Removes [tag]; returns whether it was present.
  bool remove(Tag tag) {
    final removed = _elements.remove(tag.value) != null;
    _modified |= removed;
    return removed;
  }

  void _put(Tag tag, Object canonical) {
    _elements[tag.value] = DataElement(tag, _vrFor(tag), canonical);
    _modified = true;
  }

  Vr _vrFor(Tag tag) {
    final entry = Dictionary.standard.entry(tag);
    if (entry == null || entry.vrs.isEmpty) {
      throw ArgumentError.value(
          describeTag(tag), 'tag', 'has no dictionary entry to take a VR from');
    }
    return resolveVr(entry.vrs,
        bitsAllocated: _intAt(DicomTags.bitsAllocated),
        pixelRepresentation: _intAt(DicomTags.pixelRepresentation));
  }

  int? _intAt(One<int> tag) {
    final value = _elements[tag.value]?.value;
    return value is List<int> && value.isNotEmpty ? value.first : null;
  }

  DicomParseException _wrongType(DataElement element, Type type) =>
      DicomParseException(
          'holds ${element.vr.code} data, which does not read as $type',
          tag: element.tag);

  @override
  String toString() => 'Dataset($length element${length == 1 ? '' : 's'})';
}

/// A dataset as the parser read it: not modified.
Dataset readDataset(Iterable<DataElement> elements, Uid? transferSyntax) =>
    Dataset._read(elements, transferSyntax);

/// Whether [ds] itself (not its sequence items) changed since it was read
/// or built.
bool isModified(Dataset ds) => ds._modified;
