// The in-memory model: typed reads and writes (DA1, S1), PHI-safe output.
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/src/dataset/dataset.dart' show isModified;
import 'package:test/test.dart';

void main() {
  group('typed reads', () {
    final ds = Dataset()
      ..set(DicomTags.patientName, 'Doe^Jane')
      ..set(DicomTags.rows, 512)
      ..setAll(DicomTags.windowCenter, [40.0, -600.0])
      ..setEmpty(DicomTags.studyDate);

    test('get returns the value, or null when absent or empty', () {
      expect(ds.get(DicomTags.patientName), 'Doe^Jane');
      expect(ds.get(DicomTags.rows), 512);
      expect(ds.get(DicomTags.patientId), isNull);
      expect(ds.get(DicomTags.studyDate), isNull);
      expect(ds.contains(DicomTags.studyDate), isTrue);
    });

    test('getAll returns every value, or an empty list', () {
      expect(ds.getAll(DicomTags.windowCenter), [40.0, -600.0]);
      expect(ds.getAll(DicomTags.windowWidth), isEmpty);
    });

    test('require throws a MissingElementException naming tag and keyword', () {
      expect(ds.require(DicomTags.rows), 512);
      expect(
          () => ds.require(DicomTags.sopInstanceUid),
          throwsA(isA<MissingElementException>().having((e) => e.message,
              'message', contains('(0008,0018) SOPInstanceUID'))));
    });

    test('bytes and sequences read as themselves', () {
      final item = Dataset()..set(DicomTags.referencedSopInstanceUid, '1.2');
      final withSq = Dataset()
        ..set(DicomTags.pixelData, Uint8List.fromList([1, 2]))
        ..set(DicomTags.referencedImageSequence, Sequence([item]));
      expect(withSq.get(DicomTags.pixelData), [1, 2]);
      final seq = withSq.require(DicomTags.referencedImageSequence);
      expect(seq.single.get(DicomTags.referencedSopInstanceUid), '1.2');
      expect(() => seq.add(Dataset()), throwsUnsupportedError);
    });
  });

  group('writes', () {
    test('refuse a value of the wrong Dart type at once (I-24)', () {
      final ds = Dataset();
      // These compile: T widens to Object (the I-24 gap), so set checks.
      expect(
          () => ds.set(DicomTags.rows, 'not a number'),
          throwsA(isA<ArgumentError>().having(
              (e) => '$e',
              'message',
              allOf(contains('Rows'), contains('int'), contains('String'),
                  isNot(contains('not a number'))))));
      expect(() => ds.setAll(DicomTags.windowCenter, ['not', 'numbers']),
          throwsArgumentError);
      expect(ds.contains(DicomTags.rows), isFalse);
      expect(ds.contains(DicomTags.windowCenter), isFalse);
    });

    test('keep tag order, whatever the order of calls', () {
      final ds = Dataset()
        ..set(DicomTags.rows, 1)
        ..set(DicomTags.patientName, 'X')
        ..set(DicomTags.modality, 'CT');
      expect(ds.elements.map((e) => e.tag),
          [DicomTags.modality, DicomTags.patientName, DicomTags.rows]);
    });

    test('take the VR from the dictionary, resolving ambiguity', () {
      final ds = Dataset()
        ..set(DicomTags.bitsAllocated, 16)
        ..set(DicomTags.pixelRepresentation, 1)
        ..set(DicomTags.pixelData, Uint8List(4))
        ..set(DicomTags.smallestImagePixelValue, -5);
      Vr vrOf(Tag t) => ds.elements.firstWhere((e) => e.tag == t).vr;
      expect(vrOf(DicomTags.pixelData), Vr.OW);
      expect(vrOf(DicomTags.smallestImagePixelValue), Vr.SS);
    });

    test('remove reports whether the tag was present, and marks a change', () {
      final ds = Dataset()..set(DicomTags.modality, 'CT');
      expect(ds.remove(DicomTags.modality), isTrue);
      expect(ds.remove(DicomTags.modality), isFalse);
      expect(ds.isEmpty, isTrue);
      expect(isModified(ds), isTrue);
    });
  });

  test('toString shows no values (I-9)', () {
    const sentinel = 'SENTINEL^PHI';
    final ds = Dataset()..set(DicomTags.patientName, sentinel);
    expect(ds.toString(), 'Dataset(1 element)');
    expect(ds.elements.single.toString(), isNot(contains(sentinel)));
    expect(ds.elements.single.toString(), contains('PatientName'));
  });
}
