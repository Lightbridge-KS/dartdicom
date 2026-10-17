// The write path: edits, derived file meta (I-17), strict text (I-27), bare
// datasets for DIMSE, and element header limits. VM only: starts from the
// fixtures on disk.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/io.dart';
import 'package:dartdicom/src/write/writer.dart' show swapWords;
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

  group('Pixel Data never moves between compressed and native syntaxes', () {
    test('a compressed dataset re-encoded as native is refused', () {
      final rle = _fixture('pydicom/MR_small_RLE.dcm').dataset;
      expect(
          () => rle.toBytes(
              transferSyntax: TransferSyntaxes.explicitVrLittleEndian),
          throwsA(isA<DicomWriteException>()
              .having((e) => e.message, 'message', contains('PixelData'))));
      // Its own syntax still writes.
      expect(rle.toBytes(transferSyntax: TransferSyntaxes.rleLossless),
          isNotEmpty);
    });

    test('native pixels written under a compressed syntax are refused', () {
      final ds = Dataset()
        ..set(DicomTags.bitsAllocated, 8)
        ..set(DicomTags.pixelData, Uint8List(4));
      expect(
          () => ds.toBytes(transferSyntax: TransferSyntaxes.jpegBaseline8Bit),
          throwsA(isA<DicomWriteException>()));
    });
  });

  group('Deflated (decision 3)', () {
    test('writing needs a codec that encodes, and says which', () {
      final file = _fixture('synthetic/ct_deflated.dcm');
      expect(file.toBytes, throwsA(isA<UnsupportedError>()));
    });

    test('zlib writes it, and the result reads back the same', () {
      final file = _fixture('synthetic/ct_deflated.dcm');
      final written = file.toBytes(
          options: const WriteOptions(deflateCodec: ZLibDeflateCodec()));
      final back = DicomFile.fromBytes(written);
      expect(back.meta.transferSyntaxUid,
          TransferSyntaxes.deflatedExplicitVrLittleEndian);
      expect(
          back.dataset.get(DicomTags.rows), file.dataset.get(DicomTags.rows));
    });

    test('a bare Deflated dataset (a DIMSE context) round-trips', () {
      final query = Dataset()..set(DicomTags.patientId, 'P001');
      final bytes = query.toBytes(
          transferSyntax: TransferSyntaxes.deflatedExplicitVrLittleEndian,
          deflateCodec: const ZLibDeflateCodec());
      final back = Dataset.fromBytes(bytes,
          transferSyntax: TransferSyntaxes.deflatedExplicitVrLittleEndian);
      expect(back.get(DicomTags.patientId), 'P001');
    });

    test('a malformed deflated body is a parse error', () {
      final bytes =
          File('../fixtures/data/synthetic/ct_deflated.dcm').readAsBytesSync();
      final broken = Uint8List.fromList(bytes)
        ..fillRange(bytes.length - 40, bytes.length, 0xFF);
      expect(() => DicomFile.fromBytes(broken),
          throwsA(isA<DicomParseException>()));
    });
  });

  group('across byte orders (C-11, I-18)', () {
    test('swapWords reverses each word, leaving a ragged tail', () {
      final b = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]);
      expect(swapWords(b, 2), [2, 1, 4, 3, 6, 5, 7]);
      expect(swapWords(b, 4), [4, 3, 2, 1, 5, 6, 7]);
      expect(swapWords(b, 1), same(b));
    });

    test('writing Big Endian is refused, naming the fix', () {
      final ds = Dataset()..set(DicomTags.patientId, 'P');
      expect(
          () =>
              ds.toBytes(transferSyntax: TransferSyntaxes.explicitVrBigEndian),
          throwsA(isA<DicomWriteException>().having((e) => e.message, 'message',
              contains('explicitVrLittleEndian'))));
    });

    test('Implicit, Explicit and Deflated re-encode each other', () {
      final file = _fixture('synthetic/ct_signed_explicit_le.dcm');
      for (final ts in [
        TransferSyntaxes.implicitVrLittleEndian,
        TransferSyntaxes.deflatedExplicitVrLittleEndian,
        TransferSyntaxes.explicitVrLittleEndian,
      ]) {
        final back = DicomFile.fromBytes(file.toBytes(
            options: WriteOptions(
                transferSyntax: ts, deflateCodec: const ZLibDeflateCodec())));
        expect(back.meta.transferSyntaxUid, ts);
        expect(back.dataset.require(DicomTags.pixelData),
            file.dataset.require(DicomTags.pixelData));
        expect(back.dataset.getAll(DicomTags.windowCenter),
            file.dataset.getAll(DicomTags.windowCenter));
      }
    });
  });

  group('group lengths (retired) are written only while they hold', () {
    Uint8List write(Dataset ds) =>
        ds.toBytes(transferSyntax: TransferSyntaxes.explicitVrLittleEndian);
    const groupLength = Tag.of(0x0008, 0x0000);

    test('a correct one is kept, a stale one dropped', () {
      final ds = Dataset()..set(DicomTags.modality, 'CT');
      // (0008,0060) CS 'CT' is 8 + 2 = 10 bytes in Explicit VR.
      ds.setRaw(groupLength, Vr.UL, [10]);
      final kept = Dataset.fromBytes(write(ds),
          transferSyntax: TransferSyntaxes.explicitVrLittleEndian);
      expect(kept.contains(groupLength), isTrue);

      ds.set(DicomTags.studyDate, '20260101');
      final dropped = Dataset.fromBytes(write(ds),
          transferSyntax: TransferSyntaxes.explicitVrLittleEndian);
      expect(dropped.contains(groupLength), isFalse);
      expect(dropped.get(DicomTags.studyDate), '20260101');
    });
  });
}
