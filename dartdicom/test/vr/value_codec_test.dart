// Per-VR decode and encode (data architecture §3.4). Runs on the VM and on
// the web, where 64-bit values and int precision differ.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/src/vr/value_codec.dart';
import 'package:test/test.dart';

import '../../tool/gen_dictionary/value_types.dart';

const _tag = Tag.of(0x0011, 0x1001);

Object _decode(Vr vr, List<int> bytes,
        {bool littleEndian = true, List<String> charset = const []}) =>
    decodeValue(_tag, vr, Uint8List.fromList(bytes),
        littleEndian: littleEndian, specificCharacterSet: charset);

Object _decodeText(Vr vr, String text, {List<String> charset = const []}) =>
    _decode(vr, latin1.encode(text), charset: charset);

Uint8List _encode(Vr vr, Object value,
        {bool littleEndian = true, List<String> charset = const []}) =>
    encodeValue(_tag, vr, value,
        littleEndian: littleEndian, specificCharacterSet: charset);

void main() {
  group('the VR → Dart contract (I-19) holds at runtime', () {
    final sample = <Vr, List<int>>{
      for (final vr in Vr.values) vr: List.filled(8, 0x31), // '1' × 8
    };
    for (final vr in Vr.values.where((v) => v != Vr.SQ)) {
      test(vr.code, () {
        final value = _decode(vr, sample[vr]!);
        final type = dartTypeOf(vr);
        final matches = switch (type) {
          'Uint8List' => value is Uint8List,
          'String' => value is List<String>,
          'double' => value is List<double>,
          'int' => value is List<int>,
          'BigInt' => value is List<BigInt>,
          'Tag' => value is List<Tag>,
          _ => false,
        };
        expect(matches, isTrue, reason: '${vr.code} decoded to $value');
      });
    }
  });

  test('familyOf agrees with the generator\'s contract (I-19)', () {
    const names = {
      ValueFamily.string: 'String',
      ValueFamily.int: 'int',
      ValueFamily.double: 'double',
      ValueFamily.bigInt: 'BigInt',
      ValueFamily.tag: 'Tag',
      ValueFamily.bytes: 'Uint8List',
      ValueFamily.sequence: 'Sequence',
    };
    for (final vr in Vr.values) {
      expect(names[familyOf(vr)], dartTypeOf(vr), reason: vr.code);
    }
  });

  group('text is stripped as pydicom strips it', () {
    test('multi-valued text splits on backslash after trailing padding', () {
      expect(_decodeText(Vr.CS, r'ORIGINAL\PRIMARY\AXIAL '),
          ['ORIGINAL', 'PRIMARY', 'AXIAL']);
      expect(_decodeText(Vr.UI, '1.2.3\x00'), ['1.2.3']);
      expect(_decodeText(Vr.UI, '1.2.3 '), ['1.2.3']);
    });

    test('AE strips both ends of each value', () {
      expect(_decodeText(Vr.AE, r' ORTHANC \ X '), ['ORTHANC', 'X']);
    });

    test('LO, SH and UC strip each value; LT, ST and UT never split', () {
      expect(_decodeText(Vr.LO, r'a \b '), ['a', 'b']);
      expect(_decodeText(Vr.LT, r'a\b  '), [r'a\b']);
      expect(_decodeText(Vr.UT, ' text  '), [' text']);
    });

    test('an empty value is an empty list', () {
      expect(_decodeText(Vr.PN, ''), isEmpty);
      expect(_decodeText(Vr.SH, '  '), isEmpty);
      expect(_decode(Vr.US, []), isEmpty);
    });

    test('charset-affected VRs follow (0008,0005)', () {
      final utf8Name = utf8.encode('Gómez^Łukasz');
      expect(
          _decode(Vr.PN, utf8Name, charset: ['ISO_IR 192']), ['Gómez^Łukasz']);
      expect(_decode(Vr.PN, latin1.encode('Gómez'), charset: ['ISO_IR 100']),
          ['Gómez']);
    });
  });

  group('DS and IS', () {
    test('parse each component, padding and all', () {
      expect(_decodeText(Vr.DS, r' 0.5\-1024 '), [0.5, -1024.0]);
      expect(_decodeText(Vr.IS, r'12\ -3'), [12, -3]);
      expect(_decodeText(Vr.IS, '1.0 '), [1]);
    });

    test('an empty component names the tag, never the value', () {
      expect(
          () => _decodeText(Vr.DS, r'1.5\\2'),
          throwsA(isA<DicomParseException>()
              .having((e) => e.message, 'message', contains('(0011,1001)'))));
    });

    test('I-23: any finite double writes as DS in 16 characters', () {
      final random = Random(23);
      for (var i = 0; i < 5000; i++) {
        final v = switch (i % 4) {
          0 => (random.nextDouble() - 0.5) * pow(10, random.nextInt(600) - 300),
          1 => random.nextInt(2147483647) * (random.nextBool() ? 1.0 : -1.0),
          2 => random.nextDouble() * 1000,
          _ => double.parse((random.nextDouble() * 100).toStringAsFixed(3)),
        };
        final text = latin1.decode(_encode(Vr.DS, [v])).trimRight();
        expect(text.length, lessThanOrEqualTo(16), reason: '$v → $text');
        final back = double.parse(text);
        expect(back, closeTo(v, v.abs() * 1e-7 + 1e-300), reason: '$v → $text');
      }
    });

    test('I-23: IS values within 32 bits write in 12 characters', () {
      final random = Random(12);
      for (var i = 0; i < 2000; i++) {
        // Literals, not shifts: shifts are 32-bit on the web.
        final v = random.nextInt(4294967295) - 2147483648;
        final text = latin1.decode(_encode(Vr.IS, [v])).trimRight();
        expect(text.length, lessThanOrEqualTo(12), reason: text);
        expect(int.parse(text), v);
      }
      expect(
          () => _encode(Vr.IS, [1 << 31]), throwsA(isA<DicomWriteException>()));
    });

    test('written DS values fit 16 characters', () {
      for (final v in [1 / 3, -1e-300, 123456789.123456789, 40.0]) {
        final text = latin1.decode(_encode(Vr.DS, [v])).trimRight();
        expect(text.length, lessThanOrEqualTo(16), reason: text);
        expect(double.parse(text), closeTo(v, v.abs() * 1e-9));
      }
    });
  });

  group('binary numbers', () {
    test('round-trip in both byte orders', () {
      for (final le in [true, false]) {
        for (final (vr, values) in [
          (Vr.US, [0, 0xFFFF]),
          (Vr.SS, [-0x8000, 0x7FFF]),
          (Vr.UL, [0, 0xFFFFFFFF]),
          (Vr.SL, [-0x80000000, 0x7FFFFFFF]),
          (Vr.FD, [-1.5, 1e300]),
          (Vr.FL, [0.5, -2.0]),
        ]) {
          final bytes = _encode(vr, values, littleEndian: le);
          expect(_decode(vr, bytes, littleEndian: le), values,
              reason: '${vr.code} le=$le');
        }
      }
    });

    test('SV and UV are exact BigInts across the whole 64-bit range', () {
      final uv = [BigInt.zero, (BigInt.one << 64) - BigInt.one];
      final sv = [-(BigInt.one << 63), (BigInt.one << 63) - BigInt.one];
      for (final le in [true, false]) {
        expect(
            _decode(Vr.UV, _encode(Vr.UV, uv, littleEndian: le),
                littleEndian: le),
            uv);
        expect(
            _decode(Vr.SV, _encode(Vr.SV, sv, littleEndian: le),
                littleEndian: le),
            sv);
      }
    });

    test('AT decodes to tags', () {
      expect(_decode(Vr.AT, [0x10, 0x00, 0x10, 0x00]),
          [const Tag.of(0x0010, 0x0010)]);
    });

    test('a length that is not a multiple of the size is a parse error', () {
      expect(
          () => _decode(Vr.US, [1, 2, 3]), throwsA(isA<DicomParseException>()));
    });

    test('an out-of-range value is a write error', () {
      expect(
          () => _encode(Vr.US, [70000]), throwsA(isA<DicomWriteException>()));
    });
  });

  group('encoding pads to even length', () {
    test('UI with NUL, other text with space, bytes with zero', () {
      expect(_encode(Vr.UI, ['1.2.3']), latin1.encode('1.2.3\x00'));
      expect(_encode(Vr.CS, ['CT']), latin1.encode('CT'));
      expect(_encode(Vr.CS, ['MR1']), latin1.encode('MR1 '));
      expect(_encode(Vr.OB, Uint8List.fromList([1, 2, 3])), [1, 2, 3, 0]);
    });
  });

  group('writing text is strict (F35, I-27)', () {
    test('non-ASCII text with no Specific Character Set fails with the fix',
        () {
      expect(
          () => _encode(Vr.PN, ['Gómez']),
          throwsA(isA<DicomWriteException>().having((e) => e.message, 'message',
              allOf(contains('ISO_IR 192'), isNot(contains('Gómez'))))));
    });

    test('text Latin-1 cannot encode fails under ISO_IR 100', () {
      expect(() => _encode(Vr.LO, ['Łukasz'], charset: ['ISO_IR 100']),
          throwsA(isA<DicomWriteException>()));
    });

    test('UTF-8 encodes anything under ISO_IR 192', () {
      expect(_encode(Vr.LO, ['Łukasz'], charset: ['ISO_IR 192']),
          utf8.encode('Łukasz '));
    });
  });
}
