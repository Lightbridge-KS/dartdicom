// The pixel corpus gate (M4): every native pydicom-data file decodes to
// pydicom's pixel array (dtype, shape and sha256), and every grayscale one
// agrees with pydicom's LUTs (I-33): each a ratchet over its list in
// expected.dart.
//
// The corpus and pydicom's goldens live in the user cache:
//   cd fixtures && uv run fixtures corpus fetch && uv run fixtures golden --corpus
// Absent cache: skipped locally, a failure where DARTDICOM_CORPUS_REQUIRED
// is set (the CI corpus job).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';
import 'package:test/test.dart';

import '../support/golden.dart';
import 'expected.dart';

const _corpus = 'pydicom-data';

void main() {
  final cache = cacheRoot();
  final goldenRoot = Directory('$cache/golden/$_corpus');
  final corpusRoot = '$cache/corpus/$_corpus';
  final required =
      Platform.environment.containsKey('DARTDICOM_CORPUS_REQUIRED');
  final present = goldenRoot.existsSync();

  test('native pydicom-data pixels agree with pydicom (sha256, dtype, shape)',
      () {
    if (!present) {
      fail('no corpus golden at ${goldenRoot.path}; run `uv run fixtures '
          'corpus fetch && uv run fixtures golden --corpus` in fixtures/');
    }
    final failures = <String, String>{};
    var compared = 0;
    final goldens = goldenRoot
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final golden in goldens) {
      final record =
          jsonDecode(golden.readAsStringSync()) as Map<String, Object?>;
      final pixels = record['pixels'];
      final ts = record['transfer_syntax'];
      // pydicom decoded it, and it is native.
      if (pixels is! Map<String, Object?> || pixels['sha256'] == null) continue;
      if (ts is! String || (TransferSyntax.of(Uid(ts))?.encapsulated ?? true)) {
        continue;
      }
      final path = record['file']! as String;
      compared++;
      try {
        final ds = DicomFile.fromBytes(
                File('$corpusRoot/$path').readAsBytesSync(),
                options: ReadOptions(force: record['force'] == true))
            .dataset;
        final all = ds.pixels.allFrames();
        final problems = [
          if (all.dtype.name != pixels['dtype'])
            'dtype ${all.dtype.name}, pydicom ${pixels['dtype']}',
          if ('${pydicomShape(all.shape)}' != '${pixels['shape']}')
            'shape ${pydicomShape(all.shape)}, pydicom ${pixels['shape']}',
          if (sha256.convert(leBytes(all.values, all.dtype)).toString() !=
              pixels['sha256'])
            'sha256 differs',
        ];
        if (problems.isNotEmpty) failures[path] = problems.join('; ');
      } on DicomException catch (e) {
        failures[path] = e.message;
      }
    }

    _ratchet('pixel corpus: $compared native files compared', failures,
        pixelCorpusExpectedFailures, 'pixelCorpusExpectedFailures');
  }, skip: present || required ? false : 'no corpus in the cache');

  final lutRoot = Directory('$cache/lut/$_corpus');
  test('grayscale pydicom-data frames agree with pydicom\'s LUTs (I-33)', () {
    if (!lutRoot.existsSync()) {
      fail('no LUT golden at ${lutRoot.path}; run `uv run fixtures golden '
          '--corpus` in fixtures/');
    }
    final failures = <String, String>{};
    var compared = 0;
    for (final golden in lutGoldens(lutRoot)) {
      if (golden.error != null) continue; // pydicom couldn't decode it
      compared++;
      try {
        final ds = DicomFile.fromBytes(
                File('$corpusRoot/${golden.file}').readAsBytesSync())
            .dataset;
        if (lutMismatch(ds, golden) case final problem?) {
          failures[golden.file] = problem;
        }
      } on DicomException catch (e) {
        failures[golden.file] = e.message;
      }
    }
    _ratchet('LUT corpus: $compared grayscale files compared', failures,
        lutCorpusExpectedFailures, 'lutCorpusExpectedFailures');
  }, skip: present || required ? false : 'no corpus in the cache');
}

/// The ratchet over [listed], the list named [list] in expected.dart: the
/// files in [failures] must be exactly the ones it lists, so it only
/// shrinks. Prints [tally] with the counts first.
void _ratchet(String tally, Map<String, String> failures,
    List<({String file, String reason})> listed, String list) {
  final expected = {for (final e in listed) e.file: e.reason};
  final unexpected = {
    for (final MapEntry(:key, :value) in failures.entries)
      if (!expected.containsKey(key)) key: value,
  };
  final fixed = [
    for (final p in expected.keys)
      if (!failures.containsKey(p)) p
  ];
  print('$tally, ${failures.length} failing (listed: ${expected.length})');
  expect(unexpected, isEmpty,
      reason: 'new failures; fix them, or list them with a reason in '
          '$list (test/gates/expected.dart):\n'
          '${unexpected.entries.map((e) => '${e.key}: ${e.value}').join('\n')}');
  expect(fixed, isEmpty, reason: 'these now pass; remove them from $list');
}
