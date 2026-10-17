// The write path: edits, derived file meta (I-17), strict text (I-27), bare
// datasets for DIMSE, and element header limits. VM only: starts from the
// fixtures on disk.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

DicomFile _fixture(String path) =>
    DicomFile.fromBytes(File('../fixtures/data/$path').readAsBytesSync());

void main() {
  group('edits', () {
    test('a changed value is written and read back', () {
      final file = _fixture('synthetic/ct_signed_explicit_le.dcm');
      file.dataset
        ..set(DicomTags.patientName, 'Anonymous')
        ..remove(DicomTags.patientBirthDate);
      final back = DicomFile.fromBytes(file.toBytes());
      expect(back.dataset.get(DicomTags.patientName), 'Anonymous');
      expect(back.dataset.contains(DicomTags.patientBirthDate), isFalse);
      expect(
          back.dataset.get(DicomTags.rows), file.dataset.get(DicomTags.rows));
    });

    test('an edit inside a nested item rewrites its sequence', () {
      final file = _fixture('synthetic/sequences_undefined_length.dcm');
      final sqElement = file.dataset.elements.firstWhere((e) => e.vr == Vr.SQ);
      final item = (sqElement.value as Sequence).first;
      item.set(DicomTags.codeMeaning, 'Edited');
      final back = DicomFile.fromBytes(file.toBytes());
      final backItem = (back.dataset.elements
              .firstWhere((e) => e.tag == sqElement.tag)
              .value as Sequence)
          .first;
      expect(backItem.get(DicomTags.codeMeaning), 'Edited');
    });
  });

  group('file meta is derived from the dataset (I-17)', () {
    test('conflicting SOP Instance UIDs fail the write', () {
      final file = _fixture('synthetic/ct_signed_explicit_le.dcm');
      file.dataset.set(DicomTags.sopInstanceUid, '1.2.3.4');
      expect(
          file.toBytes,
          throwsA(isA<DicomWriteException>().having((e) => e.message, 'message',
              contains('MediaStorageSOPInstanceUID'))));
    });

    test('a file built in memory gets its meta from the dataset', () {
      final ds = Dataset()
        ..set(DicomTags.sopClassUid, SopClasses.ctImageStorage.value)
        ..set(DicomTags.sopInstanceUid, '1.2.3.4')
        ..set(DicomTags.modality, 'CT');
      final meta = FileMetaInformation(Dataset()
        ..set(DicomTags.transferSyntaxUid,
            TransferSyntaxes.implicitVrLittleEndian.value));
      final back = DicomFile.fromBytes(DicomFile(meta, ds).toBytes());
      expect(back.meta.mediaStorageSopInstanceUid?.value, '1.2.3.4');
      expect(
          back.meta.transferSyntaxUid, TransferSyntaxes.implicitVrLittleEndian);
      expect(back.meta.implementationClassUid, dartdicomImplementationClassUid);
      expect(
          back.dataset.transferSyntax, TransferSyntaxes.implicitVrLittleEndian);
      expect(back.dataset.get(DicomTags.modality), 'CT');
    });

    test('forInstance meta plus received bytes is a valid file', () {
      final source = _fixture('synthetic/ct_implicit_le.dcm');
      final datasetBytes = source.dataset
          .toBytes(transferSyntax: TransferSyntaxes.implicitVrLittleEndian);
      final meta = FileMetaInformation.forInstance(
          sopClassUid: SopClasses.ctImageStorage,
          sopInstanceUid: Uid(source.dataset.require(DicomTags.sopInstanceUid)),
          transferSyntax: TransferSyntaxes.implicitVrLittleEndian,
          sourceAeTitle: 'ORTHANC');
      final header = meta.toHeaderBytes();
      final stored = Uint8List.fromList([...header, ...datasetBytes]);
      final back = DicomFile.fromBytes(stored);
      expect(back.meta.sourceApplicationEntityTitle, 'ORTHANC');
      expect(stored.sublist(header.length), datasetBytes);
      expect(
          back.dataset.get(DicomTags.rows), source.dataset.get(DicomTags.rows));
    });
  });

  group('text is written strictly (F35, I-27)', () {
    test('non-ASCII text with no Specific Character Set fails, naming the tag',
        () {
      final file = _fixture('synthetic/ct_signed_explicit_le.dcm');
      file.dataset.set(DicomTags.patientName, 'Gómez^Ana');
      expect(
          file.toBytes,
          throwsA(isA<DicomWriteException>().having(
              (e) => e.message,
              'message',
              allOf(contains('PatientName'), contains("'ISO_IR 192'"),
                  isNot(contains('Gómez'))))));
    });

    test('it writes once the charset is declared', () {
      final file = _fixture('synthetic/ct_signed_explicit_le.dcm');
      file.dataset
        ..setAll(DicomTags.specificCharacterSet, ['ISO_IR 192'])
        ..set(DicomTags.patientName, 'Gómez^Ana');
      expect(
          DicomFile.fromBytes(file.toBytes())
              .dataset
              .get(DicomTags.patientName),
          'Gómez^Ana');
    });

    test('raw text is re-encoded when the charset changes', () {
      final file = _fixture('synthetic/charset_latin1.dcm');
      final name = file.dataset.require(DicomTags.patientName);
      file.dataset.setAll(DicomTags.specificCharacterSet, ['ISO_IR 192']);
      expect(
          DicomFile.fromBytes(file.toBytes())
              .dataset
              .get(DicomTags.patientName),
          name);
    });
  });

  group('bare datasets (DIMSE identifiers)', () {
    test('round-trip in both Little Endian syntaxes', () {
      final query = Dataset()
        ..set(DicomTags.queryRetrieveLevel, 'STUDY')
        ..set(DicomTags.patientId, 'P001')
        ..setEmpty(DicomTags.studyInstanceUid);
      for (final ts in [
        TransferSyntaxes.implicitVrLittleEndian,
        TransferSyntaxes.explicitVrLittleEndian,
      ]) {
        final bytes = query.toBytes(transferSyntax: ts);
        final back = Dataset.fromBytes(bytes, transferSyntax: ts);
        expect(back.get(DicomTags.patientId), 'P001');
        expect(back.contains(DicomTags.studyInstanceUid), isTrue);
        expect(back.toBytes(transferSyntax: ts), bytes);
      }
    });

    test('stopBeforePixels leaves Pixel Data out', () {
      final bytes =
          File('../fixtures/data/pydicom/CT_small.dcm').readAsBytesSync();
      final head = DicomFile.fromBytes(bytes,
          options: const ReadOptions(stopBeforePixels: true));
      expect(head.dataset.contains(DicomTags.pixelData), isFalse);
      expect(head.dataset.get(DicomTags.rows), 128);
    });
  });

  group('element headers', () {
    // LO has a 16-bit length in Explicit VR. Text pads to even length, so
    // 65534 bytes is the longest value that fits.
    Dataset withDescription(int length) =>
        Dataset()..set(DicomTags.studyDescription, 'A' * length);

    test('a short explicit VR value over 65535 bytes fails, naming the tag',
        () {
      expect(
          () => withDescription(65536)
              .toBytes(transferSyntax: TransferSyntaxes.explicitVrLittleEndian),
          throwsA(isA<DicomWriteException>().having(
              (e) => e.message,
              'message',
              allOf(contains('StudyDescription'), contains('65535'),
                  isNot(contains('AAAA'))))));
    });

    test('65534 bytes fit, and Implicit VR has room for more', () {
      for (final (ts, length) in [
        (TransferSyntaxes.explicitVrLittleEndian, 65534),
        (TransferSyntaxes.implicitVrLittleEndian, 65536),
      ]) {
        final bytes = withDescription(length).toBytes(transferSyntax: ts);
        final back = Dataset.fromBytes(bytes, transferSyntax: ts);
        expect(back.get(DicomTags.studyDescription)?.length, length);
      }
    });
  });
}
