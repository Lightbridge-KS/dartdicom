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

Iterable<File> _libraryFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

/// Resolves every URI, including alternatives in conditional directives.
Iterable<({String kind, String target, String text})> _references(
    File f) sync* {
  for (final directive in RegExp(r'''\b(import|export|part of|part)\s+[^;]+;''')
      .allMatches(f.readAsStringSync())) {
    for (final quoted
        in RegExp(r'''['"]([^'"]+)['"]''').allMatches(directive.group(0)!)) {
      final uri = quoted.group(1)!;
      final target = uri.startsWith('package:dartdicom_net/')
          ? Uri.parse('lib/${uri.substring('package:dartdicom_net/'.length)}')
              .normalizePath()
              .path
          : Uri.parse(uri).hasScheme
              ? uri
              : Uri.file(f.path).resolve(uri).normalizePath().path;
      yield (
        kind: directive.group(1)!,
        target: target,
        text: directive.group(0)!
      );
    }
  }
}

void main() {
  test('I-37: negotiation items stay behind the three-module barrel', () {
    const folder = 'lib/src/pdu/items/';
    const barrel = 'lib/src/pdu/items.dart';
    const modules = {
      '${folder}identifiers.dart': <String>[],
      '${folder}presentation_context.dart': [
        'lib/src/pdu/bytes.dart',
        '${folder}identifiers.dart',
      ],
      '${folder}user_information.dart': [
        'dart:typed_data',
        'lib/src/pdu/bytes.dart',
        '${folder}identifiers.dart',
      ],
    };
    final offenders = <String>[];
    for (final file in _libraryFiles()) {
      for (final ref in _references(file)) {
        if (!ref.target.startsWith(folder)) continue;
        final allowed = file.path == barrel && ref.kind == 'export' ||
            modules.containsKey(file.path) &&
                ref.kind == 'import' &&
                modules[file.path]!.contains(ref.target);
        if (!allowed) offenders.add('${file.path}: ${ref.kind} ${ref.target}');
      }
    }
    expect(offenders, isEmpty);
    expect(Directory(folder).listSync().whereType<File>().map((f) => f.path),
        unorderedEquals(modules.keys));
    for (final module in modules.entries) {
      expect(_references(File(module.key)).map((r) => (r.kind, r.target)),
          unorderedEquals(module.value.map((target) => ('import', target))));
    }
    final refs = _references(File(barrel)).toList();
    expect(refs.map((r) => (r.kind, r.target)),
        unorderedEquals(modules.keys.map((target) => ('export', target))));
    var residue = File(barrel).readAsStringSync();
    for (final ref in refs) {
      residue = residue.replaceFirst(ref.text, '');
    }
    expect(residue.trim(), isEmpty);
  });
  test('I-35: PDV imports and export follow the sealed PDU library', () {
    const module = 'lib/src/pdu/pdv.dart';
    final owners = <String>[];
    for (final f in _libraryFiles()) {
      for (final ref in _references(f)) {
        if (ref.target == module) owners.add('${f.path}:${ref.kind}');
      }
    }
    expect(
        owners,
        unorderedEquals([
          'lib/src/pdu/pdus.dart:export',
          'lib/src/pdu/pdus/pdu.dart:import',
        ]));
    expect(File('lib/src/pdu/pdus.dart').readAsStringSync(),
        contains("export 'pdv.dart' show Pdv;"));
    // The PDV codec remains a leaf, independent of the PDU envelope.
    expect(_imports(File(module)),
        unorderedEquals(['dart:typed_data', 'bytes.dart']));
  });

  test('I-36: PDU families share one sealed library behind the barrel', () {
    const folder = 'lib/src/pdu/pdus/';
    const entry = '${folder}pdu.dart';
    const barrel = 'lib/src/pdu/pdus.dart';
    const parts = {
      '${folder}associate.dart',
      '${folder}data.dart',
      '${folder}release_abort.dart',
    };
    final owners = <String>[];
    final offenders = <String>[];
    for (final f in _libraryFiles()) {
      for (final ref in _references(f)) {
        if (!ref.target.startsWith(folder)) continue;
        if (f.path == barrel && ref.kind == 'export' && ref.target == entry) {
          owners.add(f.path);
        } else if (f.path == entry &&
            ref.kind == 'part' &&
            parts.contains(ref.target)) {
          // Registered members of the same library.
        } else if (parts.contains(f.path) &&
            ref.kind == 'part of' &&
            ref.target == entry) {
          // A part points back to its owning library.
        } else {
          offenders.add('${f.path}: ${ref.kind} ${ref.target}');
        }
      }
    }
    expect(owners, [barrel]);
    expect(offenders, isEmpty);
    expect(Directory(folder).listSync().whereType<File>().map((f) => f.path),
        unorderedEquals([entry, ...parts]));
    final entryRefs = _references(File(entry)).toList();
    expect(entryRefs.where((r) => r.kind == 'part').map((r) => r.target),
        unorderedEquals(parts));
    expect(
        entryRefs.where((r) => r.kind != 'part').map((r) => (r.kind, r.target)),
        unorderedEquals([
          ('import', 'dart:typed_data'),
          ('import', 'lib/src/pdu/bytes.dart'),
          ('import', 'lib/src/pdu/items.dart'),
          ('import', 'lib/src/pdu/pdv.dart'),
        ]));
    for (final part in parts) {
      expect(_references(File(part)).map((r) => (r.kind, r.target)),
          [('part of', entry)]);
    }
    // The compatibility facade contains only its two exports.
    final barrelRefs = _references(File(barrel)).toList();
    expect(
        barrelRefs.map((r) => (r.kind, r.target)),
        unorderedEquals([
          ('export', 'lib/src/pdu/pdv.dart'),
          ('export', entry),
        ]));
    var residue = File(barrel).readAsStringSync();
    for (final ref in barrelRefs) {
      residue = residue.replaceFirst(ref.text, '');
    }
    expect(residue.trim(), isEmpty);
    expect(File(entry).readAsStringSync(), contains('sealed class Pdu'));
  });

  test('I-34: only dul.dart imports the PDU observation projection', () {
    const projection = 'lib/src/dul/pdu_observations.dart';
    final owners = <String>[];
    final offenders = <String>[];
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      for (final directive
          in RegExp(r'''\b(?:import|export|part)\s+['"]([^'"]+)['"]''')
              .allMatches(f.readAsStringSync())) {
        final uri = directive.group(1)!;
        final target = uri.startsWith('package:dartdicom_net/')
            ? Uri.parse('lib/${uri.substring('package:dartdicom_net/'.length)}')
            : Uri.file(f.path).resolve(uri);
        if (target.normalizePath().path == projection) {
          if (f.path == 'lib/src/dul/dul.dart' &&
              directive.group(0)!.startsWith('import')) {
            owners.add(f.path);
          } else {
            offenders.add('${f.path} references $uri');
          }
        }
      }
    }
    expect(owners, ['lib/src/dul/dul.dart']);
    expect(offenders, isEmpty);
    // Projection is a leaf over lower layers; it cannot reach back into Dul.
    expect(_imports(File(projection)),
        unorderedEquals(['../pdu/pdus.dart', '../trace/observations.dart']));
  });

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
      'trace': 0,
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
          // print(), and top-level `var`, `late` or non-const `final`
          // (a `final class` declares a type, not state).
          if (RegExp(r'(?<![\w.])print\(|^(?:var|late)\s|^final\s+(?!class\b)')
              .hasMatch(line))
            '${f.path}:${i + 1}',
    ];
    expect(offenders, isEmpty);
  });
}
