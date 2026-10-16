// I-19: the VR → Dart type contract (data architecture §3.4). Every typed
// tag carries these types, so a change here is a breaking change.
import 'package:dartdicom/src/vr/vr.dart';
import 'package:test/test.dart';

import '../../tool/gen_dictionary/value_types.dart';

void main() {
  const contract = {
    'String': 'AE AS CS DA DT LO LT PN SH ST TM UC UI UR UT',
    'double': 'DS FD FL',
    'int': 'IS SL SS UL US',
    'BigInt': 'SV UV',
    'Uint8List': 'OB OD OF OL OV OW UN',
    'Tag': 'AT',
    'Sequence': 'SQ',
  };
  final expected = {
    for (final MapEntry(key: type, value: codes) in contract.entries)
      for (final code in codes.split(' ')) Vr.fromCode(code)!: type,
  };

  test('every VR is in the contract exactly once', () {
    expect(expected.keys.toSet(), Vr.values.toSet());
  });

  for (final vr in Vr.values) {
    test('${vr.code} → ${expected[vr]}', () {
      expect(dartTypeOf(vr), expected[vr]);
    });
  }

  test('VR alternatives type the tag only when they agree', () {
    expect(dartTypeFor([Vr.US, Vr.SS]), 'int');
    expect(dartTypeFor([Vr.OB, Vr.OW]), 'Uint8List');
    expect(dartTypeFor([Vr.US, Vr.OW]), isNull);
  });
}
