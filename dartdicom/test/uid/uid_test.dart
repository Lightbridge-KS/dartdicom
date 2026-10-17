// Transfer syntax descriptors and the implementation identity.
import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

void main() {
  test('native transfer syntaxes describe their encoding', () {
    final implicit =
        TransferSyntax.of(TransferSyntaxes.implicitVrLittleEndian)!;
    expect((implicit.explicitVr, implicit.littleEndian), (false, true));
    final be = TransferSyntax.of(TransferSyntaxes.explicitVrBigEndian)!;
    expect((be.explicitVr, be.littleEndian), (true, false));
    expect(
        TransferSyntax.of(TransferSyntaxes.deflatedExplicitVrLittleEndian)!
            .deflated,
        isTrue);
  });

  test('any other registered transfer syntax is encapsulated', () {
    final jpeg = TransferSyntax.of(TransferSyntaxes.jpegBaseline8Bit)!;
    expect((jpeg.explicitVr, jpeg.littleEndian, jpeg.encapsulated),
        (true, true, true));
    expect(TransferSyntax.of(const Uid('1.2.3.4')), isNull);
  });

  test('the implementation UID is a valid UID and the name fits SH', () {
    expect(dartdicomImplementationClassUid.value,
        matches(RegExp(r'^2\.25\.[1-9][0-9]*$')));
    expect(dartdicomImplementationClassUid.value.length, lessThanOrEqualTo(64));
    expect(dartdicomImplementationVersionName.length, lessThanOrEqualTo(16));
  });

  // dart2js's Random.secure fails under Node (the SDK runtime calls the
  // `crypto` getter with the wrong receiver); browsers and the VM are fine.
  group('Uid.generate (S10)', testOn: '!node', () {
    test('defaults to 2.25 + a version 4 UUID', () {
      final uid = Uid.generate();
      expect(uid.value, matches(RegExp(r'^2\.25\.[1-9][0-9]*$')));
      expect(uid.isValid, isTrue);
      final n = BigInt.parse(uid.value.substring(5));
      expect((n >> 76).toInt() & 0xF, 4); // the version nibble
    });

    test('is unique in practice', () {
      final uids = {for (var i = 0; i < 1000; i++) Uid.generate().value};
      expect(uids, hasLength(1000));
    });

    test('with a prefix, fills 64 characters with random digits', () {
      final uid = Uid.generate(prefix: '1.2.840.99999');
      expect(uid.value, startsWith('1.2.840.99999.'));
      expect(uid.value.length, 64);
      expect(uid.isValid, isTrue);
    });

    test('a bad prefix is an ArgumentError', () {
      expect(() => Uid.generate(prefix: '1.2.'), throwsArgumentError);
      expect(() => Uid.generate(prefix: '1.02'), throwsArgumentError);
      expect(() => Uid.generate(prefix: '1.${'2' * 61}'), throwsArgumentError);
    });
  });

  test('isValid follows PS3.5 §9.1', () {
    for (final ok in ['0', '1.2.840.10008.1.2', '2.25.0', '1.0.3']) {
      expect(Uid(ok).isValid, isTrue, reason: ok);
    }
    for (final bad in [
      '',
      '1.',
      '.1',
      '1..2',
      '1.02',
      'a.1',
      '1.2 ',
      '1' * 65
    ]) {
      expect(Uid(bad).isValid, isFalse, reason: bad);
    }
  });
}
