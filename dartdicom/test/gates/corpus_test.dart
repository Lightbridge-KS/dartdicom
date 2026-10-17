// I-11 and I-10 on the cached pydicom-data corpus (M2's exit), as a ratchet:
// corpusExpectedFailures (expected.dart) lists the files that still fail,
// each with a reason. The test fails if an unlisted file fails, or a listed one passes.
//
// The corpus and pydicom's golden reading of it live in the user cache:
//   cd fixtures && uv run fixtures corpus fetch && uv run fixtures golden --corpus
// Absent cache: skipped locally, a failure where DARTDICOM_CORPUS_REQUIRED is
// set (the CI corpus job).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/io.dart';
import 'package:test/test.dart';

import '../support/f41.dart';
import '../support/golden.dart';
import 'expected.dart';

const _corpus = 'pydicom-data';

String _cacheRoot() {
  final env = Platform.environment;
  if (env['DARTDICOM_CACHE'] case final root?) return root;
  if (env['XDG_CACHE_HOME'] case final xdg?) return '$xdg/dartdicom';
  return '${env['HOME']}/.cache/dartdicom';
}

void main() {
  final cache = _cacheRoot();
  final goldenRoot = Directory('$cache/golden/$_corpus');
  final corpusRoot = '$cache/corpus/$_corpus';
  final required =
      Platform.environment.containsKey('DARTDICOM_CORPUS_REQUIRED');
  final present = goldenRoot.existsSync();

  test('the pydicom-data corpus agrees with pydicom (I-11, I-10 by F41)', () {
    if (!present) {
      fail('no corpus golden at ${goldenRoot.path}; run `uv run fixtures '
          'corpus fetch && uv run fixtures golden --corpus` in fixtures/');
    }
    final expected = {
      for (final e in corpusExpectedFailures) e.file: e.reason,
    };
    final failures = <String, String>{};
    final tolerated = <String, int>{};
    var compared = 0;
    var pydicomUnreadable = 0;

    final goldens = goldenRoot
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final golden in goldens) {
      final record =
          jsonDecode(golden.readAsStringSync()) as Map<String, Object?>;
      final path = record['file']! as String;
      final bytes = File('$corpusRoot/$path').readAsBytesSync();
      // Read as pydicom read it: with force when it needed force.
      final options = ReadOptions(force: record['force'] == true);
      if (record.containsKey('error')) {
        // pydicom can't read it at all; we must not crash on it.
        pydicomUnreadable++;
        try {
          DicomFile.fromBytes(bytes, options: options);
        } on DicomParseException {
          // A clear refusal is fine.
        }
        continue;
      }
      final DicomFile file;
      try {
        file = DicomFile.fromBytes(bytes, options: options);
      } on DicomParseException catch (e) {
        failures[path] = 'read: ${e.message}';
        continue;
      }
      compared++;
      final compare = GoldenCompare()..file(record, file);
      for (final MapEntry(:key, :value) in compare.tolerated.entries) {
        tolerated[key] = (tolerated[key] ?? 0) + value;
      }
      if (compare.mismatches.isNotEmpty) {
        failures[path] = 'I-11: ${compare.mismatches.first}'
            '${compare.mismatches.length > 1 ? ' (+${compare.mismatches.length - 1} more)' : ''}';
        continue;
      }
      final roundTrip =
          checkF41(file, bytes, deflateCodec: const ZLibDeflateCodec());
      if (roundTrip != null) failures[path] = roundTrip;
    }

    final unexpected = {
      for (final MapEntry(:key, :value) in failures.entries)
        if (!expected.containsKey(key)) key: value,
    };
    final fixed = [
      for (final p in expected.keys)
        if (!failures.containsKey(p)) p
    ];
    print('corpus: ${goldens.length} files, $compared compared, '
        '${failures.length} failing (listed: ${expected.length}), '
        '$pydicomUnreadable unreadable by pydicom; tolerated: $tolerated');
    expect(unexpected, isEmpty,
        reason: 'new failures; fix them, or list them with a reason in '
            'corpusExpectedFailures (test/gates/expected.dart):\n'
            '${unexpected.entries.map((e) => '${e.key}: ${e.value}').join('\n')}');
    expect(fixed, isEmpty,
        reason: 'these now pass; remove them from corpusExpectedFailures');
  }, skip: present || required ? false : 'no corpus in the cache');
}
