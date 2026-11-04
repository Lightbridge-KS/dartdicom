import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/src/charset/charset.dart' show decodeText;
import 'package:test/test.dart';

void main() {
  test('supported declarations include the absent/default repertoire', () {
    for (final terms in <List<String>>[
      [],
      [''],
      [' ISO_IR 6 '],
      ['ISO_IR 100'],
      ['ISO_IR 192'],
    ]) {
      expect(characterSetSupport(terms), CharacterSetSupport.supported);
    }
  });

  test('unknown and code-extension declarations remain explicitly unsupported',
      () {
    for (final terms in [
      ['ISO_IR 166'],
      ['ISO 2022 IR 6'],
      ['ISO 2022 IR 100'],
      ['', 'ISO_IR 100'],
      ['ISO_IR 100', 'ISO_IR 192'],
    ]) {
      expect(characterSetSupport(terms), CharacterSetSupport.unsupported);
    }
  });

  test('support reporting leaves permissive fallback decoding unchanged', () {
    final bytes = Uint8List.fromList([0x63, 0x61, 0x66, 0xe9]);
    for (final terms in [
      ['ISO_IR 166'],
      ['ISO 2022 IR 100'],
    ]) {
      expect(characterSetSupport(terms), CharacterSetSupport.unsupported);
      expect(decodeText(bytes, terms), 'café');
    }
  });
}
