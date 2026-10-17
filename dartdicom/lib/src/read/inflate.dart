import 'dart:typed_data';

// Raw DEFLATE decoding (RFC 1951), in pure Dart so Deflated Explicit VR
// Little Endian reads on every platform (PRD C-08, blueprint §5, decision 3
// of M2). Modelled on Mark Adler's puff.c: canonical Huffman codes decoded
// bit by bit from per-length counts, which is short and easy to verify, and
// fast enough for the datasets DICOM deflates.

/// Compresses and decompresses raw DEFLATE data (no zlib header, as
/// PS3.5 §A.5 specifies) for the Deflated transfer syntax.
///
/// The core's default, [PureDartInflate], only decodes. Writing Deflated
/// needs a codec that encodes: `ZLibDeflateCodec` from
/// `package:dartdicom/io.dart` on native platforms, or one the caller
/// supplies on the web.
abstract interface class DeflateCodec {
  /// Decompresses [data]. Throws a [FormatException] if it is malformed,
  /// or if it would inflate past [maxLength] bytes.
  Uint8List inflate(Uint8List data, {int maxLength});

  /// Compresses [data].
  Uint8List deflate(Uint8List data);
}

/// The largest inflated dataset accepted by default: a bound against
/// deflate bombs, far above any real dataset.
const defaultMaxInflatedLength = 1 << 30;

/// Pure-Dart raw inflate; encoding is not implemented.
final class PureDartInflate implements DeflateCodec {
  const PureDartInflate();

  @override
  Uint8List inflate(Uint8List data,
          {int maxLength = defaultMaxInflatedLength}) =>
      _Inflater(data, maxLength).run();

  @override
  Uint8List deflate(Uint8List data) => throw UnsupportedError(
      'the pure-Dart DeflateCodec only decodes; to write Deflated, pass a '
      'codec that encodes (ZLibDeflateCodec from package:dartdicom/io.dart '
      'on native platforms)');
}

const _maxBits = 15;

// Lengths 257–285: base and extra bits (RFC 1951 §3.2.5).
const _lengthBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, //
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
];
const _lengthExtra = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, //
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
// Distances 0–29.
const _distanceBase = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, //
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, //
  16385, 24577,
];
const _distanceExtra = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, //
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
];
// The order code-length code lengths are sent in (§3.2.7).
const _codeLengthOrder = [
  16,
  17,
  18,
  0,
  8,
  7,
  9,
  6,
  10,
  5,
  11,
  4,
  12,
  3,
  13,
  2,
  14,
  1,
  15,
];

/// A canonical Huffman code: how many codes of each length, and the
/// symbols in code order.
final class _Huffman {
  _Huffman(List<int> lengths) : symbols = Int32List(lengths.length) {
    for (final l in lengths) {
      counts[l]++;
    }
    counts[0] = 0;
    final offsets = Int32List(_maxBits + 2);
    for (var len = 1; len <= _maxBits; len++) {
      offsets[len + 1] = offsets[len] + counts[len];
    }
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      if (lengths[symbol] != 0) symbols[offsets[lengths[symbol]]++] = symbol;
    }
  }

  final counts = Int32List(_maxBits + 1);
  final Int32List symbols;
}

final class _Inflater {
  _Inflater(this._in, this._maxLength);

  final Uint8List _in;
  final int _maxLength;
  var _inPos = 0;
  var _bitBuffer = 0;
  var _bitCount = 0;

  late var _out = Uint8List(_maxLength < 1 << 16 ? _maxLength : 1 << 16);
  var _outLen = 0;

  Uint8List run() {
    var last = false;
    while (!last) {
      last = _bits(1) == 1;
      switch (_bits(2)) {
        case 0:
          _stored();
        case 1:
          _codes(_fixed.litLen, _fixed.dist);
        case 2:
          final (litLen, dist) = _dynamicTables();
          _codes(litLen, dist);
        default:
          throw const FormatException('deflate: invalid block type');
      }
    }
    return Uint8List.sublistView(_out, 0, _outLen);
  }

  /// The fixed codes (§3.2.6), built on first use.
  late final _fixed = (
    litLen: _Huffman([
      for (var i = 0; i < 144; i++) 8,
      for (var i = 144; i < 256; i++) 9,
      for (var i = 256; i < 280; i++) 7,
      for (var i = 280; i < 288; i++) 8,
    ]),
    dist: _Huffman(List<int>.filled(30, 5)),
  );

  int _bits(int need) {
    var value = _bitBuffer;
    while (_bitCount < need) {
      if (_inPos >= _in.length) {
        throw const FormatException('deflate: the data ends inside a block');
      }
      value |= _in[_inPos++] << _bitCount;
      _bitCount += 8;
    }
    _bitBuffer = value >> need;
    _bitCount -= need;
    return value & ((1 << need) - 1);
  }

  void _emit(int byte) {
    if (_outLen == _out.length) _grow(_outLen + 1);
    _out[_outLen++] = byte;
  }

  void _grow(int need) {
    if (need > _maxLength) {
      throw FormatException(
          'deflate: the data inflates past the $_maxLength-byte limit');
    }
    var size = _out.length * 2;
    while (size < need) {
      size *= 2;
    }
    if (size > _maxLength) size = _maxLength;
    _out = Uint8List(size)..setRange(0, _outLen, _out);
  }

  void _stored() {
    _bitBuffer = 0; // go to a byte boundary
    _bitCount = 0;
    if (_inPos + 4 > _in.length) {
      throw const FormatException('deflate: the data ends in a stored block');
    }
    final len = _in[_inPos] | _in[_inPos + 1] << 8;
    final nlen = _in[_inPos + 2] | _in[_inPos + 3] << 8;
    _inPos += 4;
    if (len != (~nlen & 0xFFFF)) {
      throw const FormatException('deflate: a stored block length is corrupt');
    }
    if (_inPos + len > _in.length) {
      throw const FormatException('deflate: the data ends in a stored block');
    }
    if (_outLen + len > _out.length) _grow(_outLen + len);
    _out.setRange(_outLen, _outLen + len, _in, _inPos);
    _outLen += len;
    _inPos += len;
  }

  int _decode(_Huffman h) {
    var code = 0; // bits read so far, MSB first
    var first = 0; // first code of the current length
    var index = 0; // index of that first code in symbols
    for (var len = 1; len <= _maxBits; len++) {
      code |= _bits(1);
      final count = h.counts[len];
      if (code - count < first) return h.symbols[index + (code - first)];
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }
    throw const FormatException('deflate: an invalid Huffman code');
  }

  void _codes(_Huffman litLen, _Huffman dist) {
    while (true) {
      final symbol = _decode(litLen);
      if (symbol < 256) {
        _emit(symbol);
      } else if (symbol == 256) {
        return;
      } else {
        final s = symbol - 257;
        if (s >= 29) throw const FormatException('deflate: an invalid length');
        final length = _lengthBase[s] + _bits(_lengthExtra[s]);
        final d = _decode(dist);
        if (d >= 30) {
          throw const FormatException('deflate: an invalid distance');
        }
        final distance = _distanceBase[d] + _bits(_distanceExtra[d]);
        if (distance > _outLen) {
          throw const FormatException('deflate: a distance before the start');
        }
        if (_outLen + length > _out.length) _grow(_outLen + length);
        for (var i = 0; i < length; i++) {
          _out[_outLen] = _out[_outLen - distance];
          _outLen++;
        }
      }
    }
  }

  (_Huffman, _Huffman) _dynamicTables() {
    final nLen = _bits(5) + 257;
    final nDist = _bits(5) + 1;
    final nCode = _bits(4) + 4;
    if (nLen > 286 || nDist > 30) {
      throw const FormatException('deflate: too many codes');
    }
    final codeLengths = List<int>.filled(19, 0);
    for (var i = 0; i < nCode; i++) {
      codeLengths[_codeLengthOrder[i]] = _bits(3);
    }
    final lengthCode = _Huffman(codeLengths);
    final lengths = List<int>.filled(nLen + nDist, 0);
    var i = 0;
    while (i < nLen + nDist) {
      final symbol = _decode(lengthCode);
      if (symbol < 16) {
        lengths[i++] = symbol;
        continue;
      }
      final (repeat, value) = switch (symbol) {
        16 when i > 0 => (3 + _bits(2), lengths[i - 1]),
        16 => throw const FormatException('deflate: a repeat with no length'),
        17 => (3 + _bits(3), 0),
        _ => (11 + _bits(7), 0),
      };
      if (i + repeat > nLen + nDist) {
        throw const FormatException('deflate: too many code lengths');
      }
      for (var r = 0; r < repeat; r++) {
        lengths[i++] = value;
      }
    }
    if (lengths[256] == 0) {
      throw const FormatException('deflate: no end-of-block code');
    }
    return (
      _Huffman(lengths.sublist(0, nLen)),
      _Huffman(lengths.sublist(nLen)),
    );
  }
}
