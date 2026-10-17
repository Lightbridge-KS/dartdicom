import 'dart:typed_data';

import '../../errors.dart';
import '../../tag/tag.dart';
import '../vr.dart';

// The binary number family: US SS UL SL FL FD SV UV, and AT (a pair of
// 16-bit numbers). Fixed-size values, so always of even length.

/// Decodes the number value [bytes] in [endian] order.
List<Object> decodeNumbers(Tag tag, Vr vr, Uint8List bytes, Endian endian) {
  final size = _sizeOf(vr);
  if (bytes.length % size != 0) {
    throw DicomParseException(
        'a ${vr.code} value must be a multiple of $size bytes long, '
        'but is ${bytes.length}',
        tag: tag);
  }
  final data = ByteData.sublistView(bytes);
  List<T> numbers<T>(T Function(int offset) read) => List<T>.unmodifiable(
      [for (var i = 0; i < bytes.length; i += size) read(i)]);

  return switch (vr) {
    // The type arguments are the I-19 contract: without them, T is inferred
    // from the List<Object> return type rather than from each reader.
    Vr.US => numbers<int>((i) => data.getUint16(i, endian)),
    Vr.SS => numbers<int>((i) => data.getInt16(i, endian)),
    Vr.UL => numbers<int>((i) => data.getUint32(i, endian)),
    Vr.SL => numbers<int>((i) => data.getInt32(i, endian)),
    Vr.FL => numbers<double>((i) => data.getFloat32(i, endian)),
    Vr.FD => numbers<double>((i) => data.getFloat64(i, endian)),
    Vr.UV => numbers<BigInt>((i) => _read64(data, i, endian, signed: false)),
    Vr.SV => numbers<BigInt>((i) => _read64(data, i, endian, signed: true)),
    Vr.AT => numbers<Tag>((i) =>
        Tag.of(data.getUint16(i, endian), data.getUint16(i + 2, endian))),
    _ => throw StateError('no value codec for ${vr.code}'),
  };
}

/// Encodes number [values] in [endian] order, checking each fits the VR.
Uint8List encodeNumbers(Tag tag, Vr vr, List<Object> values, Endian endian) {
  final size = _sizeOf(vr);
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

/// The size in bytes of one value of a binary number VR (US … SV, AT).
int _sizeOf(Vr vr) => switch (vr) {
      Vr.US || Vr.SS => 2,
      Vr.UL || Vr.SL || Vr.FL || Vr.AT => 4,
      Vr.FD || Vr.UV || Vr.SV => 8,
      _ => throw StateError('no value codec for ${vr.code}'),
    };

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
