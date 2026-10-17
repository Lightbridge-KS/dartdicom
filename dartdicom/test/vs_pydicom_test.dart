// I-11 on the M1 slice: every element of every Little Endian fixture agrees
// with pydicom's reading of it (fixtures/data/golden/, from `fixtures
// golden`). VM only: it reads the fixtures from disk.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

import 'support/golden.dart';

/// What M1 reads: Implicit and Explicit VR Little Endian, including the
/// encapsulated (compressed) syntaxes; not Deflated or Big Endian yet.
bool _readable(String uid) {
  final ts = TransferSyntax.of(Uid(uid));
  return ts != null && ts.littleEndian && !ts.deflated;
}

void main() {
  final goldens = Directory('../fixtures/data/golden')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('the golden corpus is there', () => expect(goldens, isNotEmpty));

  for (final golden in goldens) {
    final record =
        jsonDecode(golden.readAsStringSync()) as Map<String, Object?>;
    final path = record['file'] as String;
    final bytes = File('../fixtures/data/$path').readAsBytesSync();

    if (!_readable(record['transfer_syntax']! as String)) {
      test('$path: an unsupported transfer syntax is a clear parse error', () {
        expect(
            () => DicomFile.fromBytes(bytes),
            throwsA(isA<DicomParseException>().having(
                (e) => e.message, 'message', contains('not supported'))));
      });
      continue;
    }

    test('$path agrees with pydicom', () {
      final compare = GoldenCompare()..file(record, DicomFile.fromBytes(bytes));
      expect(compare.mismatches, isEmpty);
    });
  }
}
