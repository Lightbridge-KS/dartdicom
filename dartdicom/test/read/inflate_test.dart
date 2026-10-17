// The pure-Dart inflate against zlib (RFC 1951, raw). VM only: zlib comes
// from dart:io. inflate_vectors_test.dart covers the web.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartdicom/src/read/inflate.dart';
import 'package:test/test.dart';

Uint8List _zlib(List<int> data, {int level = 6}) =>
    Uint8List.fromList(ZLibEncoder(raw: true, level: level).convert(data));

void main() {
  const inflater = PureDartInflate();
  final random = Random(1951);

  final inputs = <String, Uint8List>{
    'empty': Uint8List(0),
    'one byte': Uint8List.fromList([42]),
    'text': Uint8List.fromList(
        List.generate(20000, (i) => 'the quick brown fox '.codeUnitAt(i % 20))),
    'random (incompressible)':
        Uint8List.fromList(List.generate(100000, (_) => random.nextInt(256))),
    'long runs':
        Uint8List.fromList(List.generate(300000, (i) => (i ~/ 1000) & 0xFF)),
    'a fixture dataset':
        File('../fixtures/data/pydicom/CT_small.dcm').readAsBytesSync(),
  };

  for (final MapEntry(key: name, value: data) in inputs.entries) {
    for (final level in [0, 1, 6, 9]) {
      test('$name at zlib level $level', () {
        expect(inflater.inflate(_zlib(data, level: level)), data);
      });
    }
  }

  test('the Deflated fixtures inflate to what zlib gives', () {
    for (final path in [
      '../fixtures/data/synthetic/ct_deflated.dcm',
      '../fixtures/data/pydicom/image_dfl.dcm',
    ]) {
      final bytes = File(path).readAsBytesSync();
      // The meta group ends where the deflated body starts; find it by
      // trying offsets after the meta's group length.
      final groupLength =
          ByteData.sublistView(bytes, 140, 144).getUint32(0, Endian.little);
      final body = Uint8List.sublistView(bytes, 144 + groupLength);
      expect(inflater.inflate(body), ZLibDecoder(raw: true).convert(body),
          reason: path);
    }
  });

  test('malformed data is a FormatException', () {
    final good = _zlib(inputs['text']!);
    expect(() => inflater.inflate(Uint8List.sublistView(good, 0, 20)),
        throwsFormatException);
    expect(() => inflater.inflate(Uint8List.fromList([0xFF, 0xFF, 0xFF])),
        throwsFormatException);
  });

  test('inflating past the limit is a FormatException (deflate bombs)', () {
    final bomb = _zlib(Uint8List(1 << 20));
    expect(
        () => inflater.inflate(bomb, maxLength: 1000),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('limit'))));
    expect(inflater.inflate(bomb, maxLength: 1 << 20), hasLength(1 << 20));
  });

  test('the pure codec does not encode, and says what to use', () {
    expect(
        () => inflater.deflate(Uint8List(1)),
        throwsA(isA<UnsupportedError>().having(
            (e) => e.message, 'message', contains('ZLibDeflateCodec'))));
  });
}
