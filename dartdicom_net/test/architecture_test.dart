// Structural invariants of dartdicom_net (blueprint §4, §8). VM only: it
// reads the source tree.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

final _files = Directory('lib/src')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

String _layer(File f) => f.path.split('/')[2];

List<String> _imports(File f) => [
      for (final line in f.readAsLinesSync())
        if (RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''').firstMatch(line)
            case final m?)
          m.group(1)!,
    ];

void main() {
  test('I-6: only transport/, scp/ and sink/ import dart:io', () {
    final offenders = [
      for (final f in _files)
        if (!{'transport', 'scp', 'sink'}.contains(_layer(f)) &&
            _imports(f).contains('dart:io'))
          f.path,
    ];
    expect(offenders, isEmpty);
  });

  test('layers import downward only: association → dimse/acse → dul → pdu', () {
    const rank = {
      'pdu': 0,
      'fsm': 0,
      'transport': 0,
      'dul': 1,
      'dimse': 2,
      'acse': 2,
      'association': 3,
      'sink': 3,
      'scp': 4,
    };
    final offenders = <String>[];
    for (final f in _files.where((f) => f.path.split('/').length > 3)) {
      final from = _layer(f);
      for (final uri in _imports(f).where((u) => u.startsWith('../'))) {
        final to = uri.split('/')[1];
        if (rank.containsKey(to) && rank[to]! > rank[from]!) {
          offenders.add('${f.path} imports $uri');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('no print() and no top-level mutable state in lib/', () {
    final offenders = [
      for (final f
          in Directory('lib').listSync(recursive: true).whereType<File>())
        for (final (i, line) in f.readAsLinesSync().indexed)
          if (RegExp(r'(?<![\w.])print\(|^(?:var|late)\s').hasMatch(line))
            '${f.path}:${i + 1}',
    ];
    expect(offenders, isEmpty);
  });
}
