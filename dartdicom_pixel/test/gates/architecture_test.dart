// Structural invariants of dartdicom_pixel (blueprint §4, §8). VM only: it
// reads the source tree.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

final _files = Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

List<String> _imports(File f) => [
      for (final line in f.readAsLinesSync())
        if (RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''')
                .firstMatch(line)
            case final m?)
          m.group(1)!,
    ];

void main() {
  test('lib/ imports no platform library (blueprint §4)', () {
    final banned = RegExp(
        r'^(?:dart:io|dart:ffi|dart:html|dart:js_interop|package:flutter/)');
    final offenders = [
      for (final f in _files)
        for (final uri in _imports(f))
          if (banned.hasMatch(uri)) '${f.path} imports $uri',
    ];
    expect(offenders, isEmpty);
  });

  test('I-32: folders import downward: decode → pixel_array → display → lut',
      () {
    const rank = {'lut': 0, 'display': 1, 'pixel_array': 2, 'decode': 3};
    final offenders = <String>[];
    for (final f in _files) {
      final parts = f.path.split('/');
      if (parts.length < 4) continue; // lib/src/*.dart sits on top
      final from = parts[2];
      for (final uri in _imports(f).where((u) => u.startsWith('../'))) {
        final to = uri.split('/')[1];
        final upward = rank.containsKey(to) && rank[to]! > rank[from]!;
        // Of the files in lib/src/ itself, only errors.dart is below.
        final top = to.endsWith('.dart') && to != 'errors.dart';
        if (upward || top) offenders.add('${f.path} imports $uri');
      }
    }
    expect(offenders, isEmpty);
  });

  test('I-7: no print() and no top-level mutable state in lib/', () {
    final offenders = [
      for (final f in _files)
        for (final (i, line) in f.readAsLinesSync().indexed)
          // print(), and top-level `var`, `late` or non-const `final`
          // (a `final class` declares a type, not state).
          if (RegExp(r'(?<![\w.])print\(|^(?:var|late)\s|^final\s+(?!class\b)')
              .hasMatch(line))
            '${f.path}:${i + 1}',
    ];
    expect(offenders, isEmpty);
  });
}
