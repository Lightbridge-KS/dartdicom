// dartdicom_pixel runs on every platform: no dart:io, dart:ffi or web-only
// imports in lib/ (blueprint §4). VM only: it reads the source tree.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('lib/ imports no platform library', () {
    final banned = RegExp(
        r'''^\s*(?:import|export)\s+['"](?:dart:io|dart:ffi|dart:html|dart:js_interop|package:flutter/)''');
    final offenders = [
      for (final f
          in Directory('lib').listSync(recursive: true).whereType<File>())
        for (final (i, line) in f.readAsLinesSync().indexed)
          if (banned.hasMatch(line)) '${f.path}:${i + 1}',
    ];
    expect(offenders, isEmpty);
  });
}
