// The generated dictionary, typed tags and UIDs (DICOM 2026d).
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/src/dictionary/dictionary.g.dart';
import 'package:test/test.dart';

void main() {
  group('dictionary', () {
    test('is generated from the pinned release, with every entry', () {
      expect(dicomRelease, '2026d');
      expect(standardEntries.length, greaterThan(5000));
      expect(repeaterEntries, isNotEmpty);
    });

    test('carries VR, VM, keyword, name and retirement', () {
      final name = standardEntries[0x00100010]!;
      expect(name.vrs, [Vr.PN]);
      expect(name.vm, '1');
      expect(name.keyword, 'PatientName');
      expect(name.name, "Patient's Name");
      expect(name.retired, isFalse);
      expect(standardEntries[0x00281200]!.vrs, [Vr.US, Vr.SS, Vr.OW]);
    });

    test('includes command (0000) and file meta (0002) groups', () {
      expect(standardEntries[0x00000100]!.keyword, 'CommandField');
      expect(standardEntries[0x00020010]!.keyword, 'TransferSyntaxUID');
    });

    test('item and delimitation tags have no VR', () {
      expect(standardEntries[0xFFFEE000]!.vrs, isEmpty);
    });

    test('repeating groups match by mask', () {
      final overlayData =
          repeaterEntries.singleWhere((r) => r.entry.keyword == 'OverlayData');
      expect(0x60023000 & overlayData.mask, overlayData.match);
      expect(0x60023001 & overlayData.mask, isNot(overlayData.match));
    });
  });

  group('typed tags', () {
    test('carry value type and multiplicity (checked by the compiler)', () {
      // Each assignment compiles only if the generated type is exactly this.
      const One<String> name = DicomTags.patientName;
      const Many<double> window = DicomTags.windowCenter;
      const Many<String> imageType = DicomTags.imageType;
      const One<Sequence> refs = DicomTags.referencedImageSequence;
      const Tag lut = DicomTags.lutData; // VR alternatives disagree → untyped
      expect([
        name,
        window,
        imageType,
        refs,
        lut
      ], [
        0x00100010,
        0x00281050,
        0x00080008,
        0x00081140,
        0x00283006,
      ]);
    });

    test('repeating-group functions accept only their groups', () {
      final One<Uint8List> data = DicomTags.overlayData(0x6002);
      expect(data, 0x60023000);
      expect(() => DicomTags.overlayData(0x6003), throwsArgumentError); // odd
      expect(() => DicomTags.overlayData(0x6100), throwsArgumentError);
    });
  });

  group('UIDs', () {
    test('transfer syntaxes and SOP classes', () {
      expect(TransferSyntaxes.explicitVrLittleEndian, '1.2.840.10008.1.2.1');
      expect(TransferSyntaxes.implicitVrLittleEndian, '1.2.840.10008.1.2');
      expect(SopClasses.ctImageStorage, '1.2.840.10008.5.1.4.1.1.2');
      expect(SopClasses.verification, '1.2.840.10008.1.1');
    });

    test('storage lists storage SOP classes only', () {
      expect(SopClasses.storage, contains(SopClasses.ctImageStorage));
      expect(SopClasses.storage,
          contains(SopClasses.digitalXRayImageStorageForPresentation));
      expect(SopClasses.storage,
          isNot(contains(SopClasses.storageCommitmentPushModel)));
      expect(SopClasses.storage, isNot(contains(SopClasses.verification)));
    });
  });
}
