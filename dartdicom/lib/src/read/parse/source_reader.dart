import 'dart:typed_data';

import '../../source/byte_source.dart';

// The parser's byte access: the source read in the transfer syntax's byte
// order, and the signal that the data ended inside an element.

/// Thrown where the data ends inside an element: reading stops, and keeps
/// what came before.
final class Truncated implements Exception {
  const Truncated(this.at, this.tag);
  final int at;
  final int? tag;
}

/// Reads numbers and tags from a [ByteSource] in one byte order. A read
/// past the end throws [Truncated].
final class SourceReader {
  SourceReader(this.source, bool littleEndian)
      : endian = littleEndian ? Endian.little : Endian.big;

  final ByteSource source;
  final Endian endian;

  int u16(int at) {
    need(at, 2, null);
    return _data(at, 2).getUint16(0, endian);
  }

  int u32(int at) {
    need(at, 4, null);
    return _data(at, 4).getUint32(0, endian);
  }

  int tagAt(int at) {
    need(at, 4, null);
    final d = _data(at, 4);
    return d.getUint16(0, endian) << 16 | d.getUint16(2, endian);
  }

  int u16Of(Uint8List bytes) =>
      ByteData.sublistView(bytes).getUint16(0, endian);

  int u32Of(Uint8List bytes) =>
      ByteData.sublistView(bytes).getUint32(0, endian);

  /// Throws [Truncated] unless [n] bytes are there at [at].
  void need(int at, int n, int? tag) {
    if (at + n > source.length) throw Truncated(at, tag);
  }

  ByteData _data(int at, int n) => ByteData.sublistView(source.read(at, n));
}
