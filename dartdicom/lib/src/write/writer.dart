import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../dataset/dataset.dart';
import '../dataset/element.dart';
import '../dataset/sequence.dart';
import '../errors.dart';
import '../read/inflate.dart';
import '../tag/tags.g.dart';
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
    {List<String> inheritedCharset = const [], DeflateCodec? deflateCodec}) {
  if (!ts.littleEndian) {
    throw DicomWriteException(
        'Explicit VR Big Endian is retired and read-only (PRD C-08); write '
        'it as Explicit VR Little Endian, e.g. WriteOptions(transferSyntax: '
        'TransferSyntaxes.explicitVrLittleEndian)');
  }
  if (isPartial(ds)) {
    throw DicomWriteException('the dataset was read only in part '
        '(stopBeforePixels), so writing it would drop data; read it in full '
        'to write it');
  }
  _checkPixelEncapsulation(ds, ts);
  final out = BytesBuilder(copy: false);
  _Writer(ts).writeDataset(out, ds, inheritedCharset);
  // Deflated: the Explicit VR Little Endian body, as one raw DEFLATE stream.
  return ts.deflated
      ? (deflateCodec ?? const PureDartInflate()).deflate(out.takeBytes())
      : out.takeBytes();
}

/// Pixel Data can't move between an encapsulated (compressed) syntax and a
/// native one without a codec: copying it across would write an invalid
/// file. A dataset built in memory holds native pixels.
void _checkPixelEncapsulation(Dataset ds, TransferSyntax ts) {
  if (!ds.contains(DicomTags.pixelData)) return;
  final source =
      ds.transferSyntax == null ? null : TransferSyntax.of(ds.transferSyntax!);
  final encapsulated = source?.encapsulated ?? false;
  if (encapsulated == ts.encapsulated) return;
  throw DicomWriteException(
      encapsulated
          ? 'the Pixel Data is compressed (${source!.uid.value}) and '
              '${ts.uid.value} is native; decompressing needs a codec, which '
              'is not supported yet, so write it in its own transfer syntax'
          : 'the Pixel Data is native and ${ts.uid.value} is compressed; '
              'compressing needs a codec, which is not supported yet',
      tag: DicomTags.pixelData);
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
    final elements = ds.elements.toList();
    // Group by group: a group length (gggg,0000) is retired, and goes stale
    // when its group is re-encoded or edited, so it is written only if it
    // still equals the length of its group as written.
    for (var i = 0; i < elements.length;) {
      final group = elements[i].tag.group;
      var end = i;
      while (end < elements.length && elements[end].tag.group == group) {
        end++;
      }
      final groupLength = elements[i].tag.element == 0 ? elements[i] : null;
      final body = BytesBuilder(copy: false);
      for (final element
          in elements.sublist(groupLength == null ? i : i + 1, end)) {
        if (element.tag.value == _specificCharacterSet &&
            element.value is List<String>) {
          charset = element.value as List<String>;
        }
        _writeElement(body, element, charset, source, ds);
      }
      if (groupLength != null && _holds(groupLength, body.length)) {
        _writeElement(out, groupLength, charset, source, ds);
      }
      out.add(body.takeBytes());
      i = end;
    }
  }

  /// Whether [groupLength]'s value is [length].
  bool _holds(DataElement groupLength, int length) {
    final value = groupLength.value;
    return value is List<int> && value.length == 1 && value.single == length;
  }

  /// Writes [element], read from [source] (null if it was never read): its
  /// bytes as read when [_canCopy] allows, otherwise its value re-encoded.
  void _writeElement(BytesBuilder out, DataElement element,
      List<String> charset, TransferSyntax? source, Dataset ds) {
    final raw = rawValueOf(element);
    if (element.vr == Vr.SQ) {
      // A sequence keeps no bytes of its own: its items are written, each
      // element copied or re-encoded on its own, in the length forms read.
      final undefined = raw?.undefinedLength ?? false;
      final items = _encodeItems(element.value as Sequence, charset);
      _writeHeader(out, element, items.length, undefined: undefined);
      out.add(items);
      if (undefined) out.add(_delimiter(0xE0DD));
      return;
    }
    if (raw != null && _canCopy(element, raw, charset, source)) {
      _writeHeader(out, element, raw.bytes.length,
          undefined: raw.undefinedLength);
      out.add(raw.bytes);
      return;
    }
    var value = element.value;
    if (raw != null &&
        source != null &&
        source.littleEndian != ts.littleEndian &&
        value is Uint8List) {
      value = _swap(value, _wordSize(element, ds));
    }
    final encoded = encodeValue(element.tag, element.vr, value,
        littleEndian: ts.littleEndian, specificCharacterSet: charset);
    _writeHeader(out, element, encoded.length);
    out.add(encoded);
  }

  /// Whether [raw], the bytes of [element] as read from [source], mean the
  /// same in [ts] and can be written back unchanged (I-10).
  bool _canCopy(DataElement element, RawValue raw, List<String> charset,
      TransferSyntax? source) {
    if (source == null) return false;
    final sameEndian = source.littleEndian == ts.littleEndian;
    final sameEncoding = sameEndian && source.explicitVr == ts.explicitVr;
    final vr = element.vr;
    return (sameEndian || !_byteOrdered.contains(vr)) &&
        (!isCharsetVr(vr) || _sameTerms(raw.specificCharacterSet, charset)) &&
        (!raw.undefinedLength || sameEncoding);
  }

  /// Encodes the items of [seq], each in the length form it was read in: an
  /// undefined-length item ends with an Item Delimitation Item. A new item
  /// gets a defined length.
  Uint8List _encodeItems(Sequence seq, List<String> charset) {
    final body = BytesBuilder(copy: false);
    for (final item in seq) {
      final encoded = BytesBuilder(copy: false);
      writeDataset(encoded, item, charset);
      if (hasUndefinedLength(item)) {
        body
          ..add(_itemHeader(0xFFFFFFFF))
          ..add(encoded.takeBytes())
          ..add(_delimiter(0xE00D));
      } else {
        body
          ..add(_itemHeader(encoded.length))
          ..add(encoded.takeBytes());
      }
    }
    return body.takeBytes();
  }

  /// A delimitation item (FFFE,[element]) with length 0: E00D ends an item,
  /// E0DD a sequence.
  Uint8List _delimiter(int element) => (ByteData(8)
        ..setUint16(0, 0xFFFE, endian)
        ..setUint16(2, element, endian))
      .buffer
      .asUint8List();

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

/// VRs whose bytes depend on the byte order: binary numbers and word data.
/// Text, OB and UN read the same either way.
const _byteOrdered = {
  Vr.US, Vr.SS, Vr.UL, Vr.SL, Vr.SV, Vr.UV, Vr.FL, Vr.FD, Vr.AT, //
  Vr.OW, Vr.OF, Vr.OL, Vr.OD, Vr.OV,
};

/// The word size [element]'s bytes swap by when the byte order changes
/// (I-18): OW Pixel Data by its Bits Allocated (8-bit OW swaps in pairs, as
/// pydicom's `be_swap_ow`), other OW by 2, OF/OL by 4, OD/OV by 8; OB and
/// UN not at all (1).
int _wordSize(DataElement element, Dataset ds) => switch (element.vr) {
      Vr.OW when element.tag == DicomTags.pixelData =>
        math.max(2, (ds.get(DicomTags.bitsAllocated) ?? 16) ~/ 8),
      Vr.OW => 2,
      Vr.OF || Vr.OL => 4,
      Vr.OD || Vr.OV => 8,
      _ => 1,
    };

/// [bytes] with each [size]-byte word reversed (a copy; [size] 1 returns
/// [bytes] as is).
Uint8List swapWords(Uint8List bytes, int size) => _swap(bytes, size);

Uint8List _swap(Uint8List bytes, int size) {
  if (size <= 1) return bytes;
  final out = Uint8List(bytes.length);
  final whole = bytes.length - bytes.length % size;
  for (var at = 0; at < whole; at += size) {
    for (var k = 0; k < size; k++) {
      out[at + k] = bytes[at + size - 1 - k];
    }
  }
  out.setRange(whole, bytes.length, bytes, whole);
  return out;
}

bool _sameTerms(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].trim() != b[i].trim()) return false;
  }
  return true;
}
