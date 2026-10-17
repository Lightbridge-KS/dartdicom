// I-24: typed-tag misuse doesn't compile. Each file in test/compile_fail/ is
// analyzed on its own (the package's analysis excludes the folder, and only
// an explicit file path overrides that). The diagnostics must be exactly
// the ones its `// expect:` comments name, each on the line after its
// comment; a line after `// gap:` must still compile. VM only: it runs the
// analyzer.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

final _expect = RegExp(r'^\s*// expect: (\w+)$');
final _gap = RegExp(r'^\s*// gap: ');

void main() {
  final files = Directory('test/compile_fail')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('there is misuse to check', () => expect(files, isNotEmpty));

  for (final file in files) {
    final name = file.uri.pathSegments.last;
    test('I-24: $name fails to compile exactly where marked', () {
      final expected = <String>{};
      final gaps = <int>{};
      for (final (i, line) in file.readAsLinesSync().indexed) {
        // Line numbers are 1-based; the marked line is the next one.
        if (_expect.firstMatch(line) case final m?) {
          expected.add('${i + 2} ${m.group(1)}');
        }
        if (_gap.hasMatch(line)) gaps.add(i + 2);
      }
      expect(expected, isNotEmpty, reason: '$name marks no misuse');

      final result = Process.runSync(Platform.resolvedExecutable,
          ['analyze', '--format=machine', file.path]);
      // SEVERITY|TYPE|CODE|FILE|LINE|COLUMN|LENGTH|MESSAGE
      final found = <String>{
        for (final line in '${result.stdout}\n${result.stderr}'.split('\n'))
          if (line.split('|') case [_, _, final code, _, final at, ...])
            '$at ${code.toLowerCase()}',
      };
      final closed = {
        for (final f in found)
          if (gaps.contains(int.parse(f.split(' ').first))) f
      };
      expect(closed, isEmpty,
          reason: 'a gap no longer compiles: replace its `// gap:` with '
              '`// expect:` and amend I-24');
      expect(found, expected, reason: 'diagnostics by line in $name');
    });
  }
}
