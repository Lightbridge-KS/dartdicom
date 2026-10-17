// I-11 on the M1 slice: every element of every Little Endian fixture agrees
// with pydicom's reading of it (fixtures/data/golden/, from `fixtures
// golden`). VM only: it reads the fixtures from disk.
@TestOn('vm')
library;

import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/golden.dart';

/// Every registered transfer syntax reads (C-08).
bool _readable(String uid) => TransferSyntax.of(Uid(uid)) != null;

void main() {
  final goldens = goldenRecords(fixtureDirectory('golden'));

  test('the golden corpus is there', () => expect(goldens, isNotEmpty));

  for (final record in goldens) {
    final path = record['file'] as String;
    final bytes = fixture(path).readAsBytesSync();

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
