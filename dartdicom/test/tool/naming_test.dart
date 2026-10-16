// I-26: the keyword → identifier rule (surface S4) on its edge cases.
import 'package:test/test.dart';

import '../../tool/gen_dictionary/naming.dart';

void main() {
  const golden = {
    'PatientName': 'patientName',
    'PatientID': 'patientId',
    'SOPInstanceUID': 'sopInstanceUid',
    'StudyInstanceUID': 'studyInstanceUid',
    'RTDoseROISequence': 'rtDoseRoiSequence',
    'CTImageStorage': 'ctImageStorage',
    'ExplicitVRLittleEndian': 'explicitVrLittleEndian',
    'XRay3DFrameTypeSequence': 'xRay3DFrameTypeSequence',
    'Rows': 'rows',
    'LengthToEnd': 'lengthToEnd',
    'JPEG2000Lossless': 'jpeg2000Lossless',
    // Adjacent acronyms can't be told apart, so they fold as one word.
    'DICOSCTImageStorage': 'dicosctImageStorage',
  };
  for (final MapEntry(key: keyword, value: identifier) in golden.entries) {
    test('$keyword → $identifier', () {
      expect(identifierFor(keyword), identifier);
    });
  }

  test('a keyword that is not plain words is refused', () {
    expect(() => identifierFor(''), throwsArgumentError);
    expect(() => identifierFor('Patient Name'), throwsArgumentError);
  });
}
