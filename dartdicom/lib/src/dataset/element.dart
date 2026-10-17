import 'dart:typed_data';

import '../dictionary/dictionary.dart';
import '../source/byte_source.dart';
import '../tag/tag.dart';
import '../vr/value_codec.dart';
import '../vr/vr.dart';

/// One data element: a tag, a VR and a value (design D2).
///
/// An element read from bytes keeps its raw value bytes and decodes them on
/// first access, caching the result (C-05). It keeps the raw bytes after
/// decoding too, so an untouched element is written back byte for byte
/// (I-10). Values are never part of [toString] (I-9).
final class DataElement {
  /// An element built in memory, holding [value] in its canonical form
  /// (see `value_codec.dart`).
  DataElement(this.tag, this.vr, Object value)
      : _value = value,
        _raw = null;

  DataElement._read(this.tag, this.vr, RawValue raw, Object? decoded)
      : _raw = raw,
        _value = decoded;

  /// The attribute tag.
  final Tag tag;

  /// The value representation: as read for Explicit VR, from the dictionary
  /// for Implicit VR, `UN` when neither knows it.
  final Vr vr;

  final RawValue? _raw;
  Object? _value;

  /// The decoded value, in the form the data architecture §3.4 contract
  /// gives this VR: a `List` of values, `Uint8List` bytes, or a `Sequence`.
  ///
  /// Prefer the typed `Dataset` reads; this is for code that walks every
  /// element, such as a dump or a comparison.
  ///
  /// An undefined-length value (encapsulated Pixel Data) is its items,
  /// without the closing Sequence Delimitation Item, as in pydicom.
  Object get value => _value ??= decodeValue(
      tag,
      vr,
      _raw!.undefinedLength
          ? Uint8List.sublistView(_raw.bytes, 0, _raw.bytes.length - 8)
          : _raw.bytes,
      littleEndian: _raw.littleEndian,
      specificCharacterSet: _raw.specificCharacterSet);

  @override
  String toString() => 'DataElement(${describeTag(tag)} ${vr.code})';
}

/// How an element was encoded where it was read: its value bytes (or how
/// to load them), plus what is needed to decode them or to write them back
/// unchanged.
final class RawValue {
  /// A value whose [bytes] were read.
  RawValue(
    Uint8List bytes, {
    required this.undefinedLength,
    required this.littleEndian,
    required this.specificCharacterSet,
  })  : _bytes = bytes,
        _opener = null,
        _offset = 0,
        length = bytes.length;

  /// A deferred value (C-09): [length] bytes at [offset], loaded through
  /// [opener] on first access.
  RawValue.deferred(
    SourceOpener opener,
    int offset,
    this.length, {
    required this.undefinedLength,
    required this.littleEndian,
    required this.specificCharacterSet,
  })  : _opener = opener,
        _offset = offset;

  /// A sequence: its items hold the content, so only the length form is
  /// kept, and the writer rebuilds the bytes from the items.
  RawValue.sequence({
    required this.undefinedLength,
    required this.littleEndian,
    required this.specificCharacterSet,
  })  : _bytes = Uint8List(0),
        _opener = null,
        _offset = 0,
        length = 0;

  Uint8List? _bytes;
  final SourceOpener? _opener;
  final int _offset;

  /// The value length in bytes. For an undefined length, everything after
  /// the header up to and including the Sequence Delimitation Item.
  final int length;

  /// The value bytes, loaded through the source's opener on first access
  /// if the value was deferred (and then kept).
  Uint8List get bytes => _bytes ??= _opener!.read(_offset, length);

  /// Whether the bytes haven't been loaded yet.
  bool get isDeferred => _bytes == null;

  /// Whether the length field was `0xFFFFFFFF`.
  final bool undefinedLength;

  /// The byte order of the transfer syntax it was read in.
  final bool littleEndian;

  /// The Specific Character Set in effect where it was read.
  final List<String> specificCharacterSet;
}

/// An element as the parser read it. [decoded] is set for SQ, whose items
/// the parser builds itself.
DataElement readElement(Tag tag, Vr vr, RawValue raw, {Object? decoded}) =>
    DataElement._read(tag, vr, raw, decoded);

/// The raw encoding of [element], or `null` if it was built in memory.
RawValue? rawValueOf(DataElement element) => element._raw;
