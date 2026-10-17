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

final class _Writer {
  _Writer(this.ts) : endian = ts.littleEndian ? Endian.little : Endian.big;

  final TransferSyntax ts;
  final Endian endian;

  void writeDataset(BytesBuilder out, Dataset ds, List<String> inherited) {
    final source = ds.transferSyntax == null
        ? null
        : TransferSyntax.of(ds.transferSyntax!);
    var charset = inherited;
    for (final element in ds.elements) {
      if (element.tag.value == _specificCharacterSet) {
        charset = element.value as List<String>;
      }
      _writeElement(out, element, charset, source);
    }
  }

  /// Writes [element], read from [source] (null if it was never read): its
  /// bytes as read when [_canCopy] allows, otherwise its value re-encoded.
  void _writeElement(BytesBuilder out, DataElement element,
      List<String> charset, TransferSyntax? source) {
    final raw = rawValueOf(element);
    if (raw != null && _canCopy(element, raw, charset, source)) {
      _writeHeader(out, element, raw.bytes.length,
          undefined: raw.undefinedLength);
      out.add(raw.bytes);
      return;
    }
    final value = element.vr == Vr.SQ
        ? _encodeItems(element.value as Sequence, charset)
        : encodeValue(element.tag, element.vr, element.value,
            littleEndian: ts.littleEndian, specificCharacterSet: charset);
    _writeHeader(out, element, value.length);
    out.add(value);
  }

  /// Whether [raw], the bytes of [element] as read from [source], mean the
  /// same in [ts] and can be written back unchanged (I-10).
  bool _canCopy(DataElement element, RawValue raw, List<String> charset,
      TransferSyntax? source) {
    final sameEndian = source != null && source.littleEndian == ts.littleEndian;
    final sameEncoding = sameEndian && source.explicitVr == ts.explicitVr;
    final vr = element.vr;
    if (vr == Vr.SQ) {
      // The bytes hold every item's element headers, so they need the same
      // VR encoding too, and no item may have changed.
      return sameEncoding && !_sequenceModified(element.value as Sequence);
    }
    return sameEndian &&
        (!isCharsetVr(vr) || _sameTerms(raw.specificCharacterSet, charset)) &&
        (!raw.undefinedLength || sameEncoding);
  }

  /// Encodes the items of [seq], each with a defined length.
  Uint8List _encodeItems(Sequence seq, List<String> charset) {
    final body = BytesBuilder(copy: false);
    for (final item in seq) {
      final encoded = BytesBuilder(copy: false);
      writeDataset(encoded, item, charset);
      body
        ..add(_itemHeader(encoded.length))
        ..add(encoded.takeBytes());
    }
    return body.takeBytes();
  }

  // An element header in each encoding (PS3.5 §7.1):
  //
  //   implicit          tag(4) length32(4)               8 bytes
  //   explicit, short   tag(4) VR(2) length16(2)         8 bytes
  //   explicit, long    tag(4) VR(2) 00 00 length32(4)  12 bytes
  void _writeHeader(BytesBuilder out, DataElement element, int length,
      {bool undefined = false}) {
    final tag = element.tag;
    final vr = element.vr;
    final lengthField = undefined ? 0xFFFFFFFF : length;
    final header = ByteData(ts.explicitVr && vr.hasLongLength ? 12 : 8)
      ..setUint16(0, tag.group, endian)
      ..setUint16(2, tag.element, endian);
    if (!ts.explicitVr) {
      header.setUint32(4, lengthField, endian);
    } else {
      final code = latin1.encode(vr.code);
      header
        ..setUint8(4, code[0])
        ..setUint8(5, code[1]);
      if (vr.hasLongLength) {
        header.setUint32(8, lengthField, endian);
      } else if (length > 0xFFFF) {
        throw DicomWriteException(
            'a ${vr.code} value is $length bytes, more than the 65535 an '
            'Explicit VR element of this VR can hold',
            tag: tag);
      } else {
        header.setUint16(6, length, endian);
      }
    }
    out.add(header.buffer.asUint8List());
  }

  Uint8List _itemHeader(int length) => (ByteData(8)
        ..setUint16(0, 0xFFFE, endian)
        ..setUint16(2, 0xE000, endian)
        ..setUint32(4, length, endian))
      .buffer
      .asUint8List();
}

/// Whether [seq], or any sequence nested in it, has an item that changed
/// since it was read.
bool _sequenceModified(Sequence seq) => seq.any((item) =>
    isModified(item) ||
    item.elements.any((e) =>
        e.vr == Vr.SQ &&
        rawValueOf(e) != null &&
        _sequenceModified(e.value as Sequence)));

bool _sameTerms(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].trim() != b[i].trim()) return false;
  }
  return true;
}
