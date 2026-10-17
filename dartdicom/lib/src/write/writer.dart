import 'dart:convert';
import 'dart:typed_data';

import '../dataset/dataset.dart';
import '../dataset/element.dart';
import '../dataset/sequence.dart';
import '../errors.dart';
import '../uid/transfer_syntax.dart';
import '../vr/value_codec.dart';
import '../vr/vr.dart';

// The parser's mirror (design §4.1). An element nobody touched is copied
// byte for byte when its encoding is unchanged (I-10); everything else is
// re-encoded by the per-VR codecs. A rebuilt sequence is written with
// defined lengths.

const _specificCharacterSet = 0x00080005;

/// Encodes [ds] as a bare dataset in [ts]. [inheritedCharset] is the
/// Specific Character Set of the enclosing dataset, for sequence items.
///
/// Throws a [DicomWriteException] naming the tag when a value can't be
/// encoded; nothing is returned in that case.
Uint8List encodeDataset(Dataset ds, TransferSyntax ts,
    {List<String> inheritedCharset = const []}) {
  if (ts.deflated || !ts.littleEndian) {
    throw DicomWriteException(
        'transfer syntax ${ts.uid.value} is not supported for writing yet');
  }
  final out = BytesBuilder(copy: false);
  _Writer(ts).writeDataset(out, ds, inheritedCharset);
  return out.takeBytes();
}

/// Whether [seq], or any sequence nested in it, has an item that changed
/// since it was read.
bool sequenceModified(Sequence seq) => seq.any((item) =>
    isModified(item) ||
    item.elements.any((e) =>
        e.vr == Vr.SQ &&
        rawValueOf(e) != null &&
        sequenceModified(e.value as Sequence)));

final class _Writer {
  _Writer(this.ts) : endian = ts.littleEndian ? Endian.little : Endian.big;

  final TransferSyntax ts;
  final Endian endian;

  void writeDataset(BytesBuilder out, Dataset ds, List<String> inherited) {
    final source = ds.transferSyntax == null
        ? null
        : TransferSyntax.of(ds.transferSyntax!);
    final sameEndian = source != null && source.littleEndian == ts.littleEndian;
    final sameEncoding = sameEndian && source.explicitVr == ts.explicitVr;
    var charset = inherited;
    for (final element in ds.elements) {
      if (element.tag.value == _specificCharacterSet) {
        charset = element.value as List<String>;
      }
      _writeElement(out, element, charset,
          sameEndian: sameEndian, sameEncoding: sameEncoding);
    }
  }

  void _writeElement(
      BytesBuilder out, DataElement element, List<String> charset,
      {required bool sameEndian, required bool sameEncoding}) {
    final raw = rawValueOf(element);
    final vr = element.vr;
    if (vr == Vr.SQ) {
      final seq = element.value as Sequence;
      if (raw != null && sameEncoding && !sequenceModified(seq)) {
        _header(out, element, raw.bytes.length, undefined: raw.undefinedLength);
        out.add(raw.bytes);
      } else {
        final body = BytesBuilder(copy: false);
        for (final item in seq) {
          final encoded = BytesBuilder(copy: false);
          writeDataset(encoded, item, charset);
          body
            ..add(_itemHeader(encoded.length))
            ..add(encoded.takeBytes());
        }
        _header(out, element, body.length);
        out.add(body.takeBytes());
      }
      return;
    }
    final reusable = raw != null &&
        sameEndian &&
        (!isCharsetVr(vr) || _sameTerms(raw.specificCharacterSet, charset)) &&
        (!raw.undefinedLength || sameEncoding);
    if (reusable) {
      _header(out, element, raw.bytes.length, undefined: raw.undefinedLength);
      out.add(raw.bytes);
      return;
    }
    final value = encodeValue(element.tag, vr, element.value,
        littleEndian: ts.littleEndian, specificCharacterSet: charset);
    _header(out, element, value.length);
    out.add(value);
  }

  void _header(BytesBuilder out, DataElement element, int length,
      {bool undefined = false}) {
    final tag = element.tag;
    final vr = element.vr;
    final lengthField = undefined ? 0xFFFFFFFF : length;
    if (!ts.explicitVr) {
      out.add((ByteData(8)
            ..setUint16(0, tag.group, endian)
            ..setUint16(2, tag.element, endian)
            ..setUint32(4, lengthField, endian))
          .buffer
          .asUint8List());
      return;
    }
    final code = latin1.encode(vr.code);
    if (vr.hasLongLength) {
      out.add((ByteData(12)
            ..setUint16(0, tag.group, endian)
            ..setUint16(2, tag.element, endian)
            ..setUint8(4, code[0])
            ..setUint8(5, code[1])
            ..setUint32(8, lengthField, endian))
          .buffer
          .asUint8List());
      return;
    }
    if (length > 0xFFFF) {
      throw DicomWriteException(
          'a ${vr.code} value is $length bytes, more than the 65535 an '
          'Explicit VR element of this VR can hold',
          tag: tag);
    }
    out.add((ByteData(8)
          ..setUint16(0, tag.group, endian)
          ..setUint16(2, tag.element, endian)
          ..setUint8(4, code[0])
          ..setUint8(5, code[1])
          ..setUint16(6, length, endian))
        .buffer
        .asUint8List());
  }

  Uint8List _itemHeader(int length) => (ByteData(8)
        ..setUint16(0, 0xFFFE, endian)
        ..setUint16(2, 0xE000, endian)
        ..setUint32(4, length, endian))
      .buffer
      .asUint8List();
}

bool _sameTerms(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].trim() != b[i].trim()) return false;
  }
  return true;
}
