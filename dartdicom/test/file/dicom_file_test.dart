// DicomFile on write: the file meta derived from the dataset (I-17, data
// §5) and the implementation identity it names (M2 decision 4). VM only:
// starts from the fixtures on disk.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

DicomFile _fixture(String path) =>
    DicomFile.fromBytes(File('../fixtures/data/$path').readAsBytesSync());

void main() {
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

    test('the meta transfer syntax is the one written', () {
      final file = _fixture('synthetic/ct_signed_explicit_le.dcm');
      final back = DicomFile.fromBytes(file.toBytes(
          options: const WriteOptions(
              transferSyntax: TransferSyntaxes.implicitVrLittleEndian)));
      expect(
          back.meta.transferSyntaxUid, TransferSyntaxes.implicitVrLittleEndian);
      expect(
          back.dataset.transferSyntax, TransferSyntaxes.implicitVrLittleEndian);
    });

    test('a dataset with no SOP UIDs and no meta copy is refused', () {
      final meta = FileMetaInformation(Dataset()
        ..set(DicomTags.transferSyntaxUid,
            TransferSyntaxes.explicitVrLittleEndian.value));
      expect(
          () => DicomFile(meta, Dataset()..set(DicomTags.modality, 'CT'))
              .toBytes(),
          throwsA(isA<DicomWriteException>()
              .having((e) => e.message, 'message', contains('SOPClassUID'))));
    });
  });

  group('implementation identity (M2 decision 4)', () {
    String? classUid(Uint8List bytes) =>
        DicomFile.fromBytes(bytes).meta.implementationClassUid?.value;
    String? versionName(Uint8List bytes) => DicomFile.fromBytes(bytes)
        .meta
        .dataset
        .get(DicomTags.implementationVersionName);

    test('an untouched file keeps the writer it was read with', () {
      final file = _fixture('pydicom/CT_small.dcm');
      final original = file.meta.implementationClassUid?.value;
      expect(original, isNot(dartdicomImplementationClassUid.value));
      expect(classUid(file.toBytes()), original);
    });

    test('an edited file names dartdicom, both tags', () {
      final file = _fixture('pydicom/CT_small.dcm');
      file.dataset.set(DicomTags.patientName, 'Anonymous');
      final bytes = file.toBytes();
      expect(classUid(bytes), dartdicomImplementationClassUid.value);
      expect(versionName(bytes), dartdicomImplementationVersionName);
    });

    test('a removal, or an edit inside an item, also counts', () {
      final removed = _fixture('pydicom/CT_small.dcm');
      removed.dataset.remove(DicomTags.patientName);
      expect(
          classUid(removed.toBytes()), dartdicomImplementationClassUid.value);

      final nested = _fixture('synthetic/sequences_undefined_length.dcm');
      final sq = nested.dataset.elements.firstWhere((e) => e.vr == Vr.SQ);
      (sq.value as Sequence).first.set(DicomTags.codeMeaning, 'Edited');
      expect(classUid(nested.toBytes()), dartdicomImplementationClassUid.value);
    });

    test('a re-encoded file names dartdicom', () {
      final file = _fixture('synthetic/ct_signed_explicit_le.dcm');
      final bytes = file.toBytes(
          options: const WriteOptions(
              transferSyntax: TransferSyntaxes.implicitVrLittleEndian));
      expect(classUid(bytes), dartdicomImplementationClassUid.value);
    });

    test(
        'a missing class UID fills the pair; a missing version name stays '
        'missing beside another writer\'s UID', () {
      final ds = Dataset()
        ..set(DicomTags.sopClassUid, SopClasses.ctImageStorage.value)
        ..set(DicomTags.sopInstanceUid, '1.2.3');
      final bare = FileMetaInformation(Dataset()
        ..set(DicomTags.transferSyntaxUid,
            TransferSyntaxes.explicitVrLittleEndian.value));
      final filled = DicomFile(bare, ds).toBytes();
      expect(classUid(filled), dartdicomImplementationClassUid.value);
      expect(versionName(filled), dartdicomImplementationVersionName);

      final noVersion = DicomFile.fromBytes(filled);
      noVersion.meta.dataset
        ..set(DicomTags.implementationClassUid, '1.2.3.4.5')
        ..remove(DicomTags.implementationVersionName);
      // An edited meta counts as a change: dartdicom's pair again.
      expect(
          classUid(noVersion.toBytes()), dartdicomImplementationClassUid.value);
    });

    test('an empty File Meta Information Version (Type 1) is filled', () {
      final ds = Dataset()
        ..set(DicomTags.sopClassUid, SopClasses.ctImageStorage.value)
        ..set(DicomTags.sopInstanceUid, '1.2.3');
      final meta = FileMetaInformation(Dataset()
        ..setEmpty(DicomTags.fileMetaInformationVersion)
        ..set(DicomTags.transferSyntaxUid,
            TransferSyntaxes.explicitVrLittleEndian.value));
      final back = DicomFile.fromBytes(DicomFile(meta, ds).toBytes());
      expect(
          back.meta.dataset.get(DicomTags.fileMetaInformationVersion), [0, 1]);
    });
  });
}
