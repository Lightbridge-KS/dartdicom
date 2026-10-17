import 'dart:io';
import 'dart:typed_data';

import '../read/inflate.dart';

/// Raw DEFLATE through `dart:io`'s zlib: encodes as well as decodes, so
/// Deflated files can be written. `File.writeAsDicom` uses it by default.
final class ZLibDeflateCodec implements DeflateCodec {
  const ZLibDeflateCodec({this.level = 6});

  /// zlib's compression level, 0 (none) to 9 (best).
  final int level;

  @override
  Uint8List inflate(Uint8List data,
      {int maxLength = defaultMaxInflatedLength}) {
    final out = _Limited(maxLength);
    ZLibDecoder(raw: true).startChunkedConversion(out)
      ..add(data)
      ..close();
    return out.bytes.takeBytes();
  }

  @override
  Uint8List deflate(Uint8List data) =>
      Uint8List.fromList(ZLibEncoder(raw: true, level: level).convert(data));
}

/// Collects inflated chunks as they come, and stops a deflate bomb at
/// [maxLength] instead of after it has filled memory.
final class _Limited implements Sink<List<int>> {
  _Limited(this.maxLength);

  final int maxLength;
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    bytes.add(chunk);
    if (bytes.length > maxLength) {
      throw FormatException(
          'deflate: the data inflates past the $maxLength-byte limit');
    }
  }

  @override
  void close() {}
}
