// PDU encodings, checked byte by byte against PS3.8 §9.3, plus a captured
// A-ASSOCIATE-AC from Orthanc (DCMTK) so decoding isn't only tested against
// our own encoder.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/association/application_entity.dart';
import 'package:dartdicom_net/src/pdu/items.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:test/test.dart';

Uint8List _hex(String s) => Uint8List.fromList([
      for (final b in s.split(' ').where((b) => b.isNotEmpty))
        int.parse(b, radix: 16),
    ]);

void main() {
  group('fixed PDUs match PS3.8 byte for byte', () {
    test('A-RELEASE-RQ and -RP (§9.3.6, §9.3.7)', () {
      expect(const ReleaseRq().encode(), _hex('05 00 00 00 00 04 00 00 00 00'));
      expect(const ReleaseRp().encode(), _hex('06 00 00 00 00 04 00 00 00 00'));
    });

    test('A-ABORT (§9.3.8)', () {
      expect(const Abort(source: 2, reason: 1).encode(),
          _hex('07 00 00 00 00 04 00 00 02 01'));
    });

    test('A-ASSOCIATE-RJ (§9.3.4)', () {
      expect(const AssociateRj(result: 1, source: 1, reason: 7).encode(),
          _hex('03 00 00 00 00 04 00 01 01 07'));
    });

    test('P-DATA-TF with one PDV (§9.3.5, Annex E)', () {
      final pdu = PDataTf([
        Pdv(1, Uint8List.fromList([0xAA, 0xBB]), isCommand: true, isLast: true),
      ]);
      // PDU length 8 = one PDV item: length 4 (= 2 + data) + ID + header + data.
      expect(pdu.encode(), _hex('04 00 00 00 00 08 00 00 00 04 01 03 AA BB'));
    });
  });

  group('A-ASSOCIATE-RQ (§9.3.2)', () {
    const ae = ApplicationEntity(
      aeTitle: 'DARTDICOM',
      requestedContexts: PresentationContexts.verification,
      retrieveStorageClasses: [SopClasses.ctImageStorage],
    );
    final bytes = associateRqFor(ae, 'ORTHANC').encode();

    test('lays out the fixed header', () {
      expect(bytes[0], 0x01);
      expect(ByteData.sublistView(bytes, 6, 8).getUint16(0), 0x0001);
      expect(
          String.fromCharCodes(bytes.sublist(10, 26)), 'ORTHANC'.padRight(16));
      expect(String.fromCharCodes(bytes.sublist(26, 42)),
          'DARTDICOM'.padRight(16));
      expect(bytes.sublist(42, 74), everyElement(0));
      // The application context item follows: type 0x10, length 21.
      expect(bytes.sublist(74, 78), _hex('10 00 00 15'));
      expect(
          String.fromCharCodes(bytes.sublist(78, 99)), dicomApplicationContext);
    });

    test(
        'proposes odd context IDs, a role item per storage class, and our '
        'implementation', () {
      final rq = Pdu.decode(bytes) as AssociateRq;
      expect([for (final c in rq.contexts) c.id], [1, 3]);
      expect(rq.contexts.last.abstractSyntax, SopClasses.ctImageStorage.value);
      expect(rq.contexts.last.transferSyntaxes, [
        TransferSyntaxes.explicitVrLittleEndian.value,
        TransferSyntaxes.implicitVrLittleEndian.value,
      ]);
      final role = rq.userInformation.roles.single;
      expect((role.sopClass, role.scu, role.scp),
          (SopClasses.ctImageStorage.value, false, true));
      expect(rq.userInformation.implementationClassUid,
          dartdicomImplementationClassUid.value);
      expect(rq.userInformation.maxLength, 16384);
    });

    test('round-trips through encode and decode', () {
      expect((Pdu.decode(bytes) as AssociateRq).encode(), bytes);
    });

    test('more than 128 contexts is an ArgumentError', () {
      final many = ApplicationEntity(
          aeTitle: 'X', retrieveStorageClasses: SopClasses.storage);
      expect(() => associateRqFor(many, 'Y'), throwsArgumentError);
    });

    test('a bad AE title is an ArgumentError', () {
      expect(() => associateRqFor(const ApplicationEntity(aeTitle: 'X'), ''),
          throwsArgumentError);
      expect(
          () => associateRqFor(
              const ApplicationEntity(aeTitle: 'MUCH_TOO_LONG_TITLE'), 'Y'),
          throwsArgumentError);
    });
  });

  test("Orthanc's A-ASSOCIATE-AC decodes", () {
    final ac = Pdu.decode(
            File('test/vectors/orthanc_associate_ac.bin').readAsBytesSync())
        as AssociateAc;
    expect((ac.calledAeTitle, ac.callingAeTitle), ('ORTHANC', 'DARTDICOM'));
    expect(ac.applicationContext, dicomApplicationContext);
    final result = ac.results.single;
    expect((result.id, result.accepted, result.transferSyntax),
        (1, true, TransferSyntaxes.explicitVrLittleEndian.value));
    expect(ac.userInformation.maxLength, 16384);
    expect(ac.userInformation.implementationClassUid,
        '1.2.276.0.7230010.3.0.3.7.0');
    expect(ac.userInformation.implementationVersionName, 'OFFIS_DCMTK_370');
  });

  group('malformed PDUs are FormatExceptions (Evt19)', () {
    test('an unknown type', () {
      expect(
          () => Pdu.decode(_hex('09 00 00 00 00 00')), throwsFormatException);
    });
    test('a length that disagrees with the size', () {
      expect(() => Pdu.decode(_hex('05 00 00 00 00 08 00 00 00 00')),
          throwsFormatException);
    });
    test('a PDV running past its PDU', () {
      expect(() => Pdu.decode(_hex('04 00 00 00 00 06 00 00 00 09 01 03')),
          throwsFormatException);
    });
  });
}
