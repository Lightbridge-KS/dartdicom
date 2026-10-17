import 'dart:convert';
import 'dart:typed_data';

import '../charset/charset.dart';
import '../errors.dart';
import '../tag/tag.dart';
import 'vr.dart';

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
// value decodes to an empty list (or empty bytes). Text stripping follows
// pydicom's, so values agree with it element for element (I-11).

/// Text VRs whose values are never split on backslash.
const _singleTextVrs = {Vr.LT, Vr.ST, Vr.UT, Vr.UR};

/// Text VRs decoded with the Specific Character Set; the rest are ASCII.
const _charsetVrs = {Vr.SH, Vr.LO, Vr.ST, Vr.LT, Vr.UC, Vr.UT, Vr.PN};

/// Whether [vr] holds text (or text-encoded numbers: DS and IS).
bool isTextVr(Vr vr) => switch (vr) {
      Vr.AE ||
      Vr.AS ||
      Vr.CS ||
      Vr.DA ||
      Vr.DS ||
      Vr.DT ||
      Vr.IS ||
      Vr.LO ||
      Vr.LT ||
      Vr.PN ||
      Vr.SH ||
      Vr.ST ||
      Vr.TM ||
      Vr.UC ||
      Vr.UI ||
      Vr.UR ||
      Vr.UT =>
        true,
      _ => false,
    };

/// Whether [vr]'s text depends on the Specific Character Set.
bool isCharsetVr(Vr vr) => _charsetVrs.contains(vr);

/// Whether [vr] is one of the "other" binary VRs, held as raw bytes.
bool isBytesVr(Vr vr) => switch (vr) {
      Vr.OB || Vr.OD || Vr.OF || Vr.OL || Vr.OV || Vr.OW || Vr.UN => true,
      _ => false,
    };

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
    final parts = _decodeText(vr, bytes, specificCharacterSet);
    return switch (vr) {
      Vr.DS => List<double>.unmodifiable(parts.map((p) => _parseDs(tag, p))),
      Vr.IS => List<int>.unmodifiable(parts.map((p) => _parseIs(tag, p))),
      _ => parts,
    };
  }
  final endian = littleEndian ? Endian.little : Endian.big;
  final data = ByteData.sublistView(bytes);
  List<T> numbers<T>(int size, T Function(int offset) read) {
    if (bytes.length % size != 0) {
      throw DicomParseException(
          'a ${vr.code} value must be a multiple of $size bytes long, '
          'but is ${bytes.length}',
          tag: tag);
    }
    return List<T>.unmodifiable(
        [for (var i = 0; i < bytes.length; i += size) read(i)]);
  }

  return switch (vr) {
    Vr.US => numbers(2, (i) => data.getUint16(i, endian)),
    Vr.SS => numbers(2, (i) => data.getInt16(i, endian)),
    Vr.UL => numbers(4, (i) => data.getUint32(i, endian)),
    Vr.SL => numbers(4, (i) => data.getInt32(i, endian)),
    Vr.FL => numbers(4, (i) => data.getFloat32(i, endian)),
    Vr.FD => numbers(8, (i) => data.getFloat64(i, endian)),
    Vr.UV => numbers(8, (i) => _read64(data, i, endian, signed: false)),
    Vr.SV => numbers(8, (i) => _read64(data, i, endian, signed: true)),
    Vr.AT => numbers(
        4,
        (i) =>
            Tag.of(data.getUint16(i, endian), data.getUint16(i + 2, endian))),
    _ => throw StateError('no value codec for ${vr.code}'),
  };
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
  if (isBytesVr(vr)) {
    final bytes = value as Uint8List;
    return bytes.length.isEven
        ? bytes
        : (Uint8List(bytes.length + 1)..setAll(0, bytes));
  }
  final values = value as List<Object>;
  if (isTextVr(vr)) {
    final text = switch (vr) {
      Vr.DS => values.map((v) => _formatDs(tag, v as double)).join(r'\'),
      Vr.IS => values.map((v) => _formatIs(tag, v as int)).join(r'\'),
      _ => values.cast<String>().join(r'\'),
    };
    final encoded = isCharsetVr(vr)
        ? encodeText(text, specificCharacterSet, tag)
        : _encodeAscii(text, tag);
    if (encoded.length.isEven) return encoded;
    return Uint8List(encoded.length + 1)
      ..setAll(0, encoded)
      ..[encoded.length] = vr == Vr.UI ? 0x00 : 0x20;
  }
  final endian = littleEndian ? Endian.little : Endian.big;
  final size = switch (vr) {
    Vr.US || Vr.SS => 2,
    Vr.UL || Vr.SL || Vr.FL || Vr.AT => 4,
    _ => 8,
  };
  final data = ByteData(values.length * size);
  for (final (i, v) in values.indexed) {
    final at = i * size;
    switch (vr) {
      case Vr.US:
        data.setUint16(at, _inRange(tag, vr, v as int, 0, 0xFFFF), endian);
      case Vr.SS:
        data.setInt16(at, _inRange(tag, vr, v as int, -0x8000, 0x7FFF), endian);
      case Vr.UL:
        data.setUint32(at, _inRange(tag, vr, v as int, 0, 0xFFFFFFFF), endian);
      case Vr.SL:
        data.setInt32(
            at, _inRange(tag, vr, v as int, -0x80000000, 0x7FFFFFFF), endian);
      case Vr.FL:
        data.setFloat32(at, v as double, endian);
      case Vr.FD:
        data.setFloat64(at, v as double, endian);
      case Vr.UV || Vr.SV:
        _write64(data, at, _in64(tag, vr, v as BigInt), endian);
      case Vr.AT:
        final t = v as Tag;
        data
          ..setUint16(at, t.group, endian)
          ..setUint16(at + 2, t.element, endian);
      default:
        throw StateError('no value codec for ${vr.code}');
    }
  }
  return data.buffer.asUint8List();
}

List<String> _decodeText(
    Vr vr, Uint8List bytes, List<String> specificCharacterSet) {
  final raw = isCharsetVr(vr)
      ? decodeText(
          vr == Vr.PN ? _rstripBytes(bytes) : bytes, specificCharacterSet)
      : latin1.decode(bytes);
  if (_singleTextVrs.contains(vr)) {
    final s = vr == Vr.UR ? raw.trimRight() : _rstrip(raw);
    return s.isEmpty ? const [] : List.unmodifiable([s]);
  }
  final List<String> parts;
  switch (vr) {
    case Vr.AE:
      parts = [for (final p in raw.split(r'\')) p.trim()];
    case Vr.LO || Vr.SH || Vr.UC:
      parts = [for (final p in raw.split(r'\')) _rstrip(p)];
    default:
      parts = _rstrip(raw).split(r'\');
  }
  if (parts.length == 1 && parts.single.isEmpty) return const [];
  return List<String>.unmodifiable(parts);
}

double _parseDs(Tag tag, String text) {
  final value = double.tryParse(text.trim());
  if (value == null) {
    throw DicomParseException('a DS value component is empty or not a number',
        tag: tag);
  }
  return value;
}

int _parseIs(Tag tag, String text) {
  final trimmed = text.trim();
  final value = int.tryParse(trimmed) ??
      switch (double.tryParse(trimmed)) {
        final d? when d == d.truncateToDouble() => d.toInt(),
        _ => null,
      };
  if (value == null) {
    throw DicomParseException(
        'an IS value component is empty or not an integer',
        tag: tag);
  }
  return value;
}

String _formatDs(Tag tag, double value) {
  if (!value.isFinite) {
    throw DicomWriteException('a DS value must be finite', tag: tag);
  }
  var text = value.toString();
  for (var digits = 15; text.length > 16 && digits > 0; digits--) {
    text = value.toStringAsPrecision(digits);
  }
  if (text.length > 16) {
    throw DicomWriteException('a DS value cannot be written in 16 characters',
        tag: tag);
  }
  return text;
}

String _formatIs(Tag tag, int value) {
  if (value < -2147483648 || value > 2147483647) {
    throw DicomWriteException('an IS value must fit in 32 bits', tag: tag);
  }
  return value.toString();
}

Uint8List _encodeAscii(String text, Tag tag) {
  if (text.codeUnits.any((c) => c > 0x7F)) {
    throw DicomWriteException('this VR allows ASCII characters only', tag: tag);
  }
  return ascii.encode(text);
}

String _rstrip(String s) {
  var end = s.length;
  while (end > 0 &&
      (s.codeUnitAt(end - 1) == 0x20 || s.codeUnitAt(end - 1) == 0)) {
    end--;
  }
  return s.substring(0, end);
}

Uint8List _rstripBytes(Uint8List b) {
  var end = b.length;
  while (end > 0 && (b[end - 1] == 0x20 || b[end - 1] == 0)) {
    end--;
  }
  return Uint8List.sublistView(b, 0, end);
}

int _inRange(Tag tag, Vr vr, int v, int min, int max) {
  if (v < min || v > max) {
    throw DicomWriteException('a ${vr.code} value must be in $min..$max',
        tag: tag);
  }
  return v;
}

BigInt _in64(Tag tag, Vr vr, BigInt v) {
  final two63 = BigInt.one << 63;
  final ok = vr == Vr.UV
      ? v >= BigInt.zero && v < two63 * BigInt.two
      : v >= -two63 && v < two63;
  if (!ok) {
    throw DicomWriteException('a ${vr.code} value must fit in 64 bits',
        tag: tag);
  }
  return v;
}

// 64-bit values go through two 32-bit halves: ByteData.getInt64 is missing
// under dart2js, and a Dart int is exact only to 2^53 there.
BigInt _read64(ByteData data, int at, Endian endian, {required bool signed}) {
  final lo = data.getUint32(endian == Endian.little ? at : at + 4, endian);
  final hi = data.getUint32(endian == Endian.little ? at + 4 : at, endian);
  final v = BigInt.from(hi) << 32 | BigInt.from(lo);
  return signed && hi & 0x80000000 != 0 ? v - (BigInt.one << 64) : v;
}

void _write64(ByteData data, int at, BigInt v, Endian endian) {
  final u = v.isNegative ? v + (BigInt.one << 64) : v;
  final mask32 = BigInt.from(0xFFFFFFFF);
  final lo = (u & mask32).toInt();
  final hi = (u >> 32 & mask32).toInt();
  data
    ..setUint32(endian == Endian.little ? at : at + 4, lo, endian)
    ..setUint32(endian == Endian.little ? at + 4 : at, hi, endian);
}
