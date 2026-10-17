// Structural invariants of the core package (blueprint §8). VM only: it reads
// the source tree with dart:io, which the core library itself never imports.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

final _libFiles = Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

/// `lib/io.dart` and `lib/src/io/` form the native adapter (blueprint §4).
bool _isNativeAdapter(File f) =>
    f.path == 'lib/io.dart' || f.path.startsWith('lib/src/io/');

/// Top-level mutable state: `var`/`late`/non-const `final`, or a typed
/// declaration with an initializer, starting at column 0 (I-7).
final _topLevelMutable = RegExp(
  r'^(?:(?:var|late)\s|final\s(?!class\b)|(?!const\b|return\b|typedef\b)[A-Za-z_][\w<>?, ]*\s+[a-z_]\w*\s*=)',
);

List<String> _offenders(Iterable<File> files, RegExp pattern) => [
      for (final f in files)
        for (final (i, line) in f.readAsLinesSync().indexed)
          if (pattern.hasMatch(line)) '${f.path}:${i + 1}: ${line.trim()}',
    ];

void main() {
  test('I-1: core lib/ imports no platform library (outside the io adapter)',
      () {
    final banned = RegExp(
      r'''^\s*(?:import|export)\s+['"](?:dart:io|dart:ffi|dart:html|dart:js_interop|package:flutter/)''',
    );
    expect(_offenders(_libFiles.where((f) => !_isNativeAdapter(f)), banned),
        isEmpty);
  });

  test('I-5: dataset/ imports nothing from read/ or write/ (but dataset.dart)',
      () {
    // dataset.dart alone may, for Dataset.fromBytes / toBytes (F38).
    final dataset = _libFiles.where((f) =>
        f.path.startsWith('lib/src/dataset/') &&
        f.path != 'lib/src/dataset/dataset.dart');
    final banned = RegExp(r'''^\s*import\s+['"].*(?:/read/|/write/)''');
    expect(_offenders(dataset, banned), isEmpty);
  });

  test('I-5: read/ and write/ import nothing from file/', () {
    final codecs = _libFiles.where((f) =>
        f.path.startsWith('lib/src/read/') ||
        f.path.startsWith('lib/src/write/'));
    final banned = RegExp(r'''^\s*import\s+['"].*/file/''');
    expect(_offenders(codecs, banned), isEmpty);
  });

  test('I-29: only vr/value_codec.dart imports vr/codec/', () {
    final banned =
        RegExp(r'''^\s*(?:import|export)\s+['"](?:codec/|.*/vr/codec/)''');
    bool isBarrel(File f) => f.path == 'lib/src/vr/value_codec.dart';
    // Guard the guard: the barrel's own imports match the pattern.
    expect(_offenders(_libFiles.where(isBarrel), banned), isNotEmpty);
    final others = _libFiles
        .where((f) => !isBarrel(f) && !f.path.startsWith('lib/src/vr/codec/'));
    expect(_offenders(others, banned), isEmpty);
  });

  test('I-31: only read/parser.dart imports read/parse/', () {
    final banned =
        RegExp(r'''^\s*(?:import|export)\s+['"](?:parse/|.*/read/parse/)''');
    bool isBarrel(File f) => f.path == 'lib/src/read/parser.dart';
    // Guard the guard: the barrel's own imports match the pattern.
    expect(_offenders(_libFiles.where(isBarrel), banned), isNotEmpty);
    final others = _libFiles.where(
        (f) => !isBarrel(f) && !f.path.startsWith('lib/src/read/parse/'));
    expect(_offenders(others, banned), isEmpty);
  });

  test('F40: source/ is a leaf (only dart:typed_data and errors.dart)', () {
    final source = _libFiles.where((f) => f.path.startsWith('lib/src/source/'));
    final imports = RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''');
    final offenders = [
      for (final f in source)
        for (final line in f.readAsLinesSync())
          if (imports.firstMatch(line)?.group(1) case final uri?
              when uri != 'dart:typed_data' && !uri.endsWith('errors.dart'))
            '${f.path}: $uri',
    ];
    expect(source, isNotEmpty);
    expect(offenders, isEmpty);
  });

  test('I-7: no top-level mutable variables in lib/', () {
    // Guard the guard: the pattern must flag mutable declarations and leave
    // constants, functions and types alone.
    for (final bad in ['var x = 1;', 'final m = <int>{};', 'int n = 0;']) {
      expect(_topLevelMutable.hasMatch(bad), isTrue, reason: bad);
    }
    for (final ok in [
      'const x = 1;',
      'int f() => 1;',
      'typedef F = int;',
      'extension type const Tag(int value) {',
      'final class Sequence {',
      'abstract final class Tags {',
    ]) {
      expect(_topLevelMutable.hasMatch(ok), isFalse, reason: ok);
    }
    expect(_offenders(_libFiles, _topLevelMutable), isEmpty);
  });

  test('I-22: no temp-file or cache APIs in lib/', () {
    expect(_offenders(_libFiles, RegExp(r'systemTemp|createTemp')), isEmpty);
  });

  test('no print() in library code', () {
    expect(_offenders(_libFiles, RegExp(r'(?<![\w.])print\(')), isEmpty);
  });
}
