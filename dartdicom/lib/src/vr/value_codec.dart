import 'dart:typed_data';

import '../errors.dart';
import '../tag/tag.dart';
import 'codec/number_codec.dart';
import 'codec/text_codec.dart';
import 'codec/vr_family.dart';
import 'ambiguous.dart' show lutDescriptorTags;
import 'vr.dart';

export 'codec/vr_family.dart'
    show ValueFamily, familyOf, isBytesVr, isCharsetVr, isTextVr, numberSize;

// Per-VR conversion between value bytes and the Dart values of the data
// architecture §3.4 contract. Each VR decodes to one canonical form:
//
//   text VRs               List<String>
//   DS / IS                List<double> / List<int>
//   US SS UL SL / FL FD    List<int> / List<double>
//   SV UV                  List<BigInt>   (exact on every platform)
//   AT                     List<Tag>
//   OB OD OF OL OV OW UN   Uint8List      (one value, in the TS byte order)
//
// SQ is not a value codec's business: the parser builds its items. An empty
// value decodes to an empty list (or empty bytes).
//
// This file is the vr/ codec's only entry point: each family lives in
// codec/, and nothing else in lib/ imports codec/ (I-29).

/// Decodes the value [bytes] of element [tag] with VR [vr].
///
/// Throws a [DicomParseException] naming the tag when the bytes don't fit
/// the VR (e.g. a US value of odd length). Never for SQ.
Object decodeValue(
  Tag tag,
  Vr vr,
  Uint8List bytes, {
  required bool littleEndian,
  required List<String> specificCharacterSet,
}) {
  if (isBytesVr(vr)) return bytes;
  if (isTextVr(vr)) {
    return decodeTextValues(tag, vr, bytes, specificCharacterSet);
  }
  final numbers =
      decodeNumbers(tag, vr, bytes, littleEndian ? Endian.little : Endian.big);
  // A LUT Descriptor's first value is unsigned whatever the VR (PS3.3
  // C.11.1.1.1): read as SS, a negative one is raised by 65536, as pydicom.
  if (vr == Vr.SS && lutDescriptorTags.contains(tag.value)) {
    final values = List<int>.of(numbers as List<int>);
    if (values.isNotEmpty && values.first < 0) values[0] += 65536;
    return List<int>.unmodifiable(values);
  }
  return numbers;
}

/// Encodes [value] (a canonical form, see the top of this file) for element
/// [tag] with VR [vr], padded to even length.
///
/// Throws a [DicomWriteException] naming the tag when the value doesn't fit
/// the VR: out of range, too long, or text the character set can't encode.
Uint8List encodeValue(
  Tag tag,
  Vr vr,
  Object value, {
  required bool littleEndian,
  required List<String> specificCharacterSet,
}) {
  if (isBytesVr(vr)) return _padEven(value as Uint8List, 0x00);
  final values = value as List<Object>;
  if (isTextVr(vr)) {
    return _padEven(encodeTextValues(tag, vr, values, specificCharacterSet),
        vr == Vr.UI ? 0x00 : 0x20);
  }
  return encodeNumbers(
      tag, vr, values, littleEndian ? Endian.little : Endian.big);
}

/// [bytes], or a copy with one [pad] byte appended if its length is odd.
Uint8List _padEven(Uint8List bytes, int pad) => bytes.length.isEven
    ? bytes
    : (Uint8List(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = pad);
