// I-11 and I-10 on the cached pydicom-data corpus (M2's exit), as a ratchet:
// test/corpus_expected.txt lists the files that still fail, each with a
// reason. The test fails if an unlisted file fails, or a listed one passes.
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
import 'package:test/test.dart';

import 'support/golden.dart';

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
    final expected = _expected(File('test/corpus_expected.txt'));
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
      if (record.containsKey('error')) {
        // pydicom can't read it at all; we must not crash on it.
        pydicomUnreadable++;
        try {
          DicomFile.fromBytes(bytes);
        } on DicomParseException {
          // A clear refusal is fine.
        }
        continue;
      }
      final DicomFile file;
      try {
        file = DicomFile.fromBytes(bytes);
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
      final roundTrip = _roundTrip(file, bytes);
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
            'test/corpus_expected.txt:\n'
            '${unexpected.entries.map((e) => '${e.key}  # ${e.value}').join('\n')}');
    expect(fixed, isEmpty,
        reason: 'these now pass; remove them from test/corpus_expected.txt');
  }, skip: present || required ? false : 'no corpus in the cache');
}

/// I-10 under F41's rule: byte-identical when the read was clean, the
/// transfer syntax is written back, and the meta agrees with the dataset.
/// Returns why it failed, or null.
String? _roundTrip(DicomFile file, List<int> bytes) {
  if (file.meta.transferSyntaxUid == TransferSyntaxes.explicitVrBigEndian) {
    return null; // read-only (C-08): F41 exempts it
  }
  final metaUid = file.meta.mediaStorageSopInstanceUid?.value;
  final datasetUid = file.dataset.get(DicomTags.sopInstanceUid);
  if (metaUid != null && datasetUid != null && metaUid != datasetUid) {
    return null; // I-17 refuses it by design
  }
  final List<int> written;
  try {
    written = file.toBytes();
  } on DicomWriteException catch (e) {
    return 'I-10 write: ${e.message}';
  }
  if (written.length != bytes.length) {
    return 'I-10: ${written.length} bytes written, ${bytes.length} read';
  }
  for (var i = 0; i < bytes.length; i++) {
    if (written[i] != bytes[i]) return 'I-10: first difference at byte $i';
  }
  return null;
}

/// `path  # reason` lines; blank lines and lines starting with `#` skipped.
Map<String, String> _expected(File file) => {
      for (final line
          in file.existsSync() ? file.readAsLinesSync() : <String>[])
        if (line.trim().isNotEmpty && !line.trimLeft().startsWith('#'))
          line.split('#').first.trim(): line.contains('#')
              ? line.substring(line.indexOf('#') + 1).trim()
              : '',
    };
