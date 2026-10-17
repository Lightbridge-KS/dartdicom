// The untyped side of the dataset API: family getters (F36), element(),
// setRaw (S1) and private blocks (S9). Runs on every platform.
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

const _private = Tag.of(0x0009, 0x1001);

void main() {
  group('untyped getters', () {
    final ds = Dataset()
      ..setRaw(_private, Vr.LO, ['a', 'b'])
      ..setRaw(const Tag.of(0x0009, 0x1002), Vr.US, [1, 2])
      ..setRaw(const Tag.of(0x0009, 0x1003), Vr.FD, [0.5])
      ..setRaw(const Tag.of(0x0009, 0x1004), Vr.UV, [BigInt.two])
      ..setRaw(const Tag.of(0x0009, 0x1005), Vr.AT, [DicomTags.patientName])
      ..setRaw(const Tag.of(0x0009, 0x1006), Vr.OB, Uint8List.fromList([1]))
      ..setRaw(const Tag.of(0x0009, 0x1007), Vr.SQ, Sequence([Dataset()]));

    test('read each family', () {
      expect(ds.getStrings(_private), ['a', 'b']);
      expect(ds.getInts(const Tag.of(0x0009, 0x1002)), [1, 2]);
      expect(ds.getDoubles(const Tag.of(0x0009, 0x1003)), [0.5]);
      expect(ds.getBigInts(const Tag.of(0x0009, 0x1004)), [BigInt.two]);
      expect(ds.getTags(const Tag.of(0x0009, 0x1005)), [DicomTags.patientName]);
      expect(ds.getBytes(const Tag.of(0x0009, 0x1006)), [1]);
      expect(ds.getSequence(const Tag.of(0x0009, 0x1007)), hasLength(1));
    });

    test('an absent tag is empty, or null for bytes and sequences', () {
      const absent = Tag.of(0x0009, 0x10FF);
      expect(ds.getStrings(absent), isEmpty);
      expect(ds.getBytes(absent), isNull);
      expect(ds.getSequence(absent), isNull);
    });

    test('the wrong family is a parse error naming the tag', () {
      expect(
          () => ds.getInts(_private),
          throwsA(isA<DicomParseException>()
              .having((e) => e.message, 'message', contains('(0009,1001)'))));
    });

    test('F36: a typed tag names its typed accessor', () {
      expect(
          () => Dataset().getStrings(DicomTags.patientName),
          throwsA(isA<ArgumentError>()
              .having((e) => e.message, 'message', contains('ds.get('))));
      expect(
          () => Dataset().getDoubles(DicomTags.windowCenter),
          throwsA(isA<ArgumentError>()
              .having((e) => e.message, 'message', contains('ds.getAll('))));
    });

    test('a tag whose VRs disagree on a type is untyped (US or OW)', () {
      const lutData = Tag.of(0x0028, 0x3006);
      final lut = Dataset()..setRaw(lutData, Vr.US, [1, 2, 3]);
      expect(lut.getInts(lutData), [1, 2, 3]);
    });

    test('element() reaches any tag, typed or not', () {
      final typed = Dataset()..set(DicomTags.modality, 'CT');
      expect(typed.element(DicomTags.modality)?.value, ['CT']);
      expect(ds.element(_private)?.vr, Vr.LO);
      expect(ds.element(const Tag.of(0x0011, 0x0011)), isNull);
    });
  });

  group('setRaw', () {
    test('rejects values in the wrong form for the VR', () {
      expect(() => Dataset().setRaw(_private, Vr.LO, [1]), throwsArgumentError);
      expect(() => Dataset().setRaw(_private, Vr.OB, [1]), throwsArgumentError);
    });

    test('rejects a VR the dictionary does not allow for the tag', () {
      expect(() => Dataset().setRaw(DicomTags.rows, Vr.UL, [1]),
          throwsArgumentError);
    });

    test('values survive encoding', () {
      final ds = Dataset()..setRaw(_private, Vr.LO, ['scanner-7']);
      final back = Dataset.fromBytes(
          ds.toBytes(transferSyntax: TransferSyntaxes.explicitVrLittleEndian),
          transferSyntax: TransferSyntaxes.explicitVrLittleEndian);
      expect(back.getStrings(_private), ['scanner-7']);
    });
  });

  group('private blocks (S9)', () {
    test('create reserves the first free slot, as LO', () {
      final ds = Dataset();
      final acme = ds.privateBlock(0x0009, 'ACME 1.0', create: true)!;
      expect(acme.slot, 0x10);
      expect(ds.element(const Tag.of(0x0009, 0x0010))?.vr, Vr.LO);
      expect(acme.tag(0x01), const Tag.of(0x0009, 0x1001));
      final other = ds.privateBlock(0x0009, 'OTHER', create: true)!;
      expect(other.tag(0xFF), const Tag.of(0x0009, 0x11FF));
    });

    test('an existing creator is found, a missing one is null', () {
      final ds = Dataset()..setRaw(const Tag.of(0x0019, 0x0012), Vr.LO, ['X']);
      expect(ds.privateBlock(0x0019, 'X')?.slot, 0x12);
      expect(ds.privateBlock(0x0019, 'Y'), isNull);
    });

    test('blocks read back from a file', () {
      final ds = Dataset();
      final acme = ds.privateBlock(0x0009, 'ACME 1.0', create: true)!;
      ds.setRaw(acme.tag(0x01), Vr.LO, ['scanner-7']);
      final back = Dataset.fromBytes(
          ds.toBytes(transferSyntax: TransferSyntaxes.implicitVrLittleEndian),
          transferSyntax: TransferSyntaxes.implicitVrLittleEndian);
      final found = back.privateBlock(0x0009, 'ACME 1.0')!;
      // Implicit VR: the private element itself is UN without a private
      // dictionary (F11), so it reads as bytes.
      expect(back.getBytes(found.tag(0x01)), isNotEmpty);
    });

    test('bad arguments are errors', () {
      expect(() => Dataset().privateBlock(0x0010, 'X'), throwsArgumentError);
      expect(() => Dataset().privateBlock(0x0009, ''), throwsArgumentError);
      expect(() => const PrivateBlock(0x0009, 'X', 0x10).tag(0x100),
          throwsRangeError);
    });

    test('all 240 slots taken is a StateError', () {
      final ds = Dataset();
      for (var i = 0; i < 240; i++) {
        ds.privateBlock(0x0009, 'C$i', create: true);
      }
      expect(() => ds.privateBlock(0x0009, 'one more', create: true),
          throwsStateError);
    });
  });
}
