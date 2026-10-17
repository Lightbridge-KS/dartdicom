import 'dart:collection';
import 'dart:typed_data';

import '../dictionary/dictionary.dart';
import '../errors.dart';
import '../read/inflate.dart';
import '../read/parser.dart';
import '../read/read_options.dart';
import '../source/byte_source.dart';
import '../tag/tag.dart';
import '../tag/tags.g.dart';
import '../tag/typed_tag.dart';
import '../uid/transfer_syntax.dart';
import '../uid/uid.dart';
import '../vr/ambiguous.dart';
import '../vr/value_codec.dart';
import '../vr/vr.dart';
import '../write/writer.dart';
import 'element.dart';
import 'private_block.dart';
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
  Dataset()
      : transferSyntax = null,
        _partial = false,
        _undefinedLength = false;

  /// Parses a bare dataset, with no preamble or file meta, encoded in
  /// [transferSyntax]: e.g. a DIMSE identifier. For Part 10 bytes, use
  /// `DicomFile.fromBytes`.
  ///
  /// Throws a [DicomParseException] with the offset and tag where reading
  /// stopped if the bytes can't be read.
  factory Dataset.fromBytes(Uint8List bytes,
          {required Uid transferSyntax,
          ReadOptions options = const ReadOptions()}) =>
      parseDataset(
          BytesSource(bytes), _transferSyntax(transferSyntax), options);

  Dataset._read(Iterable<DataElement> elements, this.transferSyntax,
      {bool partial = false, bool undefinedLength = false})
      : _partial = partial,
        _undefinedLength = undefinedLength {
    for (final e in elements) {
      _elements[e.tag.value] = e;
    }
  }

  /// The transfer syntax this dataset was read in, or `null` if it was
  /// built in memory. Binary values not yet re-encoded (such as Pixel
  /// Data bytes) are in its byte order.
  final Uid? transferSyntax;

  final _elements = SplayTreeMap<int, DataElement>();

  /// Read only in part (`stopBeforePixels`, …): writing it would drop data.
  final bool _partial;

  /// An SQ item read with an undefined length, written back the same way.
  final bool _undefinedLength;
  var _modified = false;

  /// Encodes this dataset alone, with no preamble or file meta, in
  /// [transferSyntax]. Untouched elements are copied byte for byte when the
  /// encoding is unchanged (I-10).
  ///
  /// Throws a [DicomWriteException] naming the tag if a value can't be
  /// encoded.
  ///
  /// Writing Deflated needs a [deflateCodec] that encodes (the core's only
  /// decodes); `ZLibDeflateCodec` from `package:dartdicom/io.dart` does.
  Uint8List toBytes(
          {required Uid transferSyntax, DeflateCodec? deflateCodec}) =>
      encodeDataset(this, _transferSyntax(transferSyntax),
          deflateCodec: deflateCodec);

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

  /// The element with [tag], or `null`: the untyped escape hatch, e.g. for
  /// code that walks elements or looks them up by keyword. Its `value` is in
  /// the form the VR → Dart contract gives (data §3.4).
  DataElement? element(Tag tag) => _elements[tag.value];

  /// Every value of the untyped [tag] as text (e.g. a private element), or
  /// an empty list.
  ///
  /// The untyped getters read tags with no typed constant: private tags, and
  /// tags whose VRs disagree on a Dart type (`US or OW`). A typed tag throws
  /// an [ArgumentError] naming its typed accessor (blueprint F36).
  List<String> getStrings(Tag tag) =>
      _list(tag, ValueFamily.string, 'getStrings');

  /// Every value of the untyped [tag] as an `int` (IS, US, SS, UL, SL).
  List<int> getInts(Tag tag) => _list(tag, ValueFamily.int, 'getInts');

  /// Every value of the untyped [tag] as a `double` (DS, FL, FD).
  List<double> getDoubles(Tag tag) =>
      _list(tag, ValueFamily.double, 'getDoubles');

  /// Every value of the untyped [tag] as a `BigInt` (SV, UV).
  List<BigInt> getBigInts(Tag tag) =>
      _list(tag, ValueFamily.bigInt, 'getBigInts');

  /// Every value of the untyped [tag] as a [Tag] (AT).
  List<Tag> getTags(Tag tag) => _list(tag, ValueFamily.tag, 'getTags');

  /// The bytes of the untyped [tag] (OB, OW, UN, …), or `null` if absent.
  Uint8List? getBytes(Tag tag) =>
      _single<Uint8List>(tag, ValueFamily.bytes, 'getBytes');

  /// The items of the untyped [tag] (SQ), or `null` if absent.
  Sequence? getSequence(Tag tag) =>
      _single<Sequence>(tag, ValueFamily.sequence, 'getSequence');

  /// Sets [tag] with an explicit [vr] (surface S1): for tags with no typed
  /// constant, such as private elements.
  ///
  /// [values] is [vr]'s form in the VR → Dart contract: a `List<String>`,
  /// `List<int>`, `List<double>`, `List<BigInt>` or `List<Tag>`, a
  /// `Uint8List`, or a [Sequence]. Throws an [ArgumentError] if it isn't, or
  /// if the dictionary knows [tag] and doesn't allow [vr].
  void setRaw(Tag tag, Vr vr, Object values) {
    final entry = Dictionary.standard.entry(tag);
    if (entry != null && entry.vrs.isNotEmpty && !entry.vrs.contains(vr)) {
      throw ArgumentError.value(vr.code, 'vr',
          '${describeTag(tag)} allows ${entry.vrs.map((v) => v.code).join(' or ')}');
    }
    final canonical = switch ((familyOf(vr), values)) {
      (ValueFamily.string, final List<String> v) =>
        List<String>.unmodifiable(v),
      (ValueFamily.int, final List<int> v) => List<int>.unmodifiable(v),
      (ValueFamily.double, final List<double> v) =>
        List<double>.unmodifiable(v),
      (ValueFamily.bigInt, final List<BigInt> v) =>
        List<BigInt>.unmodifiable(v),
      (ValueFamily.tag, final List<Tag> v) => List<Tag>.unmodifiable(v),
      (ValueFamily.bytes, final Uint8List v) => v,
      (ValueFamily.sequence, final Sequence v) => v,
      _ => throw ArgumentError.value(values.runtimeType.toString(), 'values',
          'is not the form ${vr.code} values take (data architecture §3.4)'),
    };
    _elements[tag.value] = DataElement(tag, vr, canonical);
    _modified = true;
  }

  /// The block of private elements [creator] reserves in the odd [group]
  /// (surface S9), or `null` if the dataset has none. With [create], a
  /// missing block is reserved in the first free slot.
  ///
  /// Throws an [ArgumentError] for a group that isn't private or an empty
  /// creator, and a [StateError] if [create] finds all 240 slots taken.
  PrivateBlock? privateBlock(int group, String creator, {bool create = false}) {
    if (!Tag.of(group, 0x0010).isPrivate) {
      throw ArgumentError.value(
          group.toRadixString(16), 'group', 'is not a private (odd) group');
    }
    if (creator.isEmpty) {
      throw ArgumentError.value(creator, 'creator', 'must not be empty');
    }
    int? free;
    for (var slot = 0x10; slot <= 0xFF; slot++) {
      final element = _elements[Tag.of(group, slot).value];
      if (element == null) {
        free ??= slot;
        continue;
      }
      final value = element.value;
      if (value is List<String> && value.isNotEmpty && value.first == creator) {
        return PrivateBlock(group, creator, slot);
      }
    }
    if (!create) return null;
    if (free == null) {
      throw StateError('group ${group.toRadixString(16)} has no free private '
          'creator slot');
    }
    setRaw(Tag.of(group, free), Vr.LO, [creator]);
    return PrivateBlock(group, creator, free);
  }

  List<T> _list<T extends Object>(
      Tag tag, ValueFamily family, String accessor) {
    _rejectTyped(tag, accessor);
    final element = _elements[tag.value];
    if (element == null) return const [];
    final value = element.value;
    if (familyOf(element.vr) == family && value is List<T>) return value;
    throw _wrongType(element, T);
  }

  T? _single<T extends Object>(Tag tag, ValueFamily family, String accessor) {
    _rejectTyped(tag, accessor);
    final element = _elements[tag.value];
    if (element == null) return null;
    final value = element.value;
    if (familyOf(element.vr) == family && value is T) return value;
    throw _wrongType(element, T);
  }

  /// F36: a typed tag (its dictionary VRs agree on one Dart type) must be
  /// read with `get` / `require` / `getAll`, which the compiler checks.
  void _rejectTyped(Tag tag, String accessor) {
    final entry = Dictionary.standard.entry(tag);
    if (entry == null || entry.vrs.isEmpty) return;
    if (entry.vrs.map(familyOf).toSet().length != 1) return;
    final reader = entry.vm == '1' ? 'get' : 'getAll';
    throw ArgumentError.value(
        describeTag(tag),
        'tag',
        'has a typed constant; read it with ds.$reader(DicomTags.…), not '
            '$accessor');
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

TransferSyntax _transferSyntax(Uid uid) =>
    TransferSyntax.of(uid) ??
    (throw ArgumentError.value(
        uid.value, 'transferSyntax', 'is not a registered transfer syntax'));

/// A dataset as the parser read it: not modified. [partial] marks a read
/// that stopped early; [undefinedLength] an SQ item read with an undefined
/// length.
Dataset readDataset(Iterable<DataElement> elements, Uid? transferSyntax,
        {bool partial = false, bool undefinedLength = false}) =>
    Dataset._read(elements, transferSyntax,
        partial: partial, undefinedLength: undefinedLength);

/// Whether [ds] was read only in part, so writing it would drop data.
bool isPartial(Dataset ds) => ds._partial;

/// Whether [ds], an SQ item, was read with an undefined length.
bool hasUndefinedLength(Dataset ds) => ds._undefinedLength;

/// Whether [ds] itself (not its sequence items) changed since it was read
/// or built.
bool isModified(Dataset ds) => ds._modified;
