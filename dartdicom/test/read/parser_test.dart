// The parser's walk: what a sequence item inherits from the dataset around
// it, and what it keeps to itself.
import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

Dataset _roundTrip(Dataset ds) {
  const ts = TransferSyntaxes.explicitVrLittleEndian;
  return Dataset.fromBytes(ds.toBytes(transferSyntax: ts), transferSyntax: ts);
}

void main() {
  group('sequence items and the Specific Character Set', () {
    test('an item reads its text in the character set around it', () {
      final ds = Dataset()
        ..setAll(DicomTags.specificCharacterSet, ['ISO_IR 192'])
        ..set(DicomTags.referencedPatientSequence,
            Sequence([Dataset()..set(DicomTags.patientName, 'Gómez^Ana')]));
      final item =
          _roundTrip(ds).require(DicomTags.referencedPatientSequence).first;
      expect(item.get(DicomTags.patientName), 'Gómez^Ana');
    });

    test("an item's own character set stays inside the item", () {
      final ds = Dataset()
        ..setAll(DicomTags.specificCharacterSet, ['ISO_IR 192'])
        ..set(
            DicomTags.referencedPatientSequence,
            Sequence([
              Dataset()
                ..setAll(DicomTags.specificCharacterSet, ['ISO_IR 100'])
                ..set(DicomTags.patientName, 'Müller^Jörg'),
            ]))
        // After the sequence in tag order, so it reads after the item.
        ..set(DicomTags.patientName, 'Gómez^Ana');
      final back = _roundTrip(ds);
      expect(
          back
              .require(DicomTags.referencedPatientSequence)
              .first
              .get(DicomTags.patientName),
          'Müller^Jörg');
      expect(back.get(DicomTags.patientName), 'Gómez^Ana');
    });
  });
}
