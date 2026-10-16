/// Generates the data dictionary, typed tags and UID constants from the
/// pinned DICOM release (blueprint §3; I-8, I-26).
///
/// Run from the `dartdicom` package directory (or use `just dict`):
///
///     dart run tool/gen_dictionary/main.dart             regenerate
///     dart run tool/gen_dictionary/main.dart --check     fail if stale (I-8)
///     dart run tool/gen_dictionary/main.dart --crosscheck pydicom.json
library;

import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import 'emit.dart';
import 'parse.dart';
import 'source.dart';

const _outputs = {
  'dictionary': 'lib/src/dictionary/dictionary.g.dart',
  'tags': 'lib/src/tag/tags.g.dart',
  'uids': 'lib/src/uid/uids.g.dart',
};

Future<void> main(List<String> args) async {
  final check = args.contains('--check');
  final crosscheckAt = args.indexOf('--crosscheck');

  final part06 =
      XmlDocument.parse((await fetch('part06.xml')).readAsStringSync());
  final part07 =
      XmlDocument.parse((await fetch('part07.xml')).readAsStringSync());
  _requireRelease(part06, 'PS3.6');
  _requireRelease(part07, 'PS3.7');

  // PS3.6 Table 9-1 (Dynamic RTP Payload Elements, for real-time video,
  // PS3.22) is left out, as in pydicom: those never appear in files or
  // DIMSE datasets.
  const registry = 'Registry of DICOM';
  final elements = [
    for (final caption in [
      '$registry Data Elements',
      '$registry File Meta Elements',
      '$registry Directory Structuring Elements',
    ])
      ...parseTable(part06, caption).map(elementFrom),
    ...parseTable(part07, 'Command Fields').map(elementFrom),
    ...parseTable(part07, 'Retired Command Fields')
        .map((r) => elementFrom(r, retired: true)),
  ]..sort((a, b) => a.tag.compareTo(b.tag));
  final uids = parseTable(part06, 'UID Values').map(uidFrom).toList();

  final plan = planTags(elements);
  final generated = {
    'dictionary': emitDictionary(elements),
    'tags': emitTags(plan),
    'uids': emitUids(uids),
  };

  _report(elements, uids, plan);
  if (crosscheckAt >= 0) _crosscheck(elements, File(args[crosscheckAt + 1]));

  final formatted = await _format(generated);
  if (check) {
    final stale = [
      for (final MapEntry(:key, :value) in formatted.entries)
        if (!File(_outputs[key]!).existsSync() ||
            File(_outputs[key]!).readAsStringSync() != value)
          _outputs[key]!,
    ];
    if (stale.isNotEmpty) {
      stderr.writeln('I-8: stale generated files (run `just dict`):\n  '
          '${stale.join('\n  ')}');
      exit(1);
    }
    stdout.writeln('I-8: generated files are up to date ($release)');
    return;
  }
  for (final MapEntry(:key, :value) in formatted.entries) {
    File(_outputs[key]!).writeAsStringSync(value);
    stdout.writeln('wrote ${_outputs[key]}');
  }
}

void _requireRelease(XmlDocument doc, String part) {
  final subtitle = doc.findAllElements('subtitle').first.innerText;
  if (!subtitle.contains('$part $release')) {
    throw StateError('expected DICOM $part $release, got "$subtitle"');
  }
}

/// Formats the generated sources with `dart format`, through a temporary
/// directory inside the package so the package's language version applies.
Future<Map<String, String>> _format(Map<String, String> sources) async {
  final tmp = Directory('.dart_tool/gen_dictionary')
    ..createSync(recursive: true);
  final files = {
    for (final MapEntry(:key, :value) in sources.entries)
      key: File('${tmp.path}/$key.dart')..writeAsStringSync(value),
  };
  final result =
      await Process.run('dart', ['format', ...files.values.map((f) => f.path)]);
  if (result.exitCode != 0) throw StateError('dart format: ${result.stderr}');
  return {
    for (final MapEntry(:key, :value) in files.entries)
      key: value.readAsStringSync(),
  };
}

void _report(List<Element> elements, List<UidEntry> uids, TagPlan plan) {
  final repeaters = elements.where((e) => e.isRepeater).length;
  stdout
    ..writeln('DICOM $release: ${elements.length} entries '
        '(${elements.length - repeaters} tags, $repeaters ranges), '
        '${uids.length} UIDs')
    ..writeln('typed tags: ${plan.constants.length} constants, '
        '${plan.groupFunctions.length} repeating-group functions');
  for (final MapEntry(:key, :value) in plan.skipped.entries) {
    final sample = value.take(3).map((e) => '(${e.tag})').join(', ');
    stdout.writeln(
        '  ${value.length} × $key: $sample${value.length > 3 ? ', …' : ''}');
  }
}

/// Compares against a dictionary exported from pydicom
/// (`fixtures pydicom-dictionary` in the fixtures package): {tag: [VR, VM, name, retired,
/// keyword]}. Differences are reported, not fatal: the two may follow
/// different DICOM releases.
void _crosscheck(List<Element> elements, File pydicomJson) {
  final theirs = (jsonDecode(pydicomJson.readAsStringSync()) as Map)
      .cast<String, List<dynamic>>();
  final ours = {for (final e in elements) e.tag: e};
  final onlyOurs = ours.keys.where((t) => !theirs.containsKey(t)).toList();
  final onlyTheirs = theirs.keys.where((t) => !ours.containsKey(t)).toList();
  final diffs = <String>[];
  for (final MapEntry(key: tag, value: e) in ours.entries) {
    final t = theirs[tag];
    if (t == null) continue;
    final ourVr =
        e.vrs.isEmpty ? 'NONE' : e.vrs.map((v) => v.code).join(' or ');
    final fields = {
      'VR': (ourVr, t[0] as String),
      'VM': (e.vm, t[1] as String),
      'keyword': (e.keyword, t[4] as String),
      'retired': (e.retired ? 'Retired' : '', t[3] as String),
    };
    for (final MapEntry(key: field, value: (a, b)) in fields.entries) {
      if (a != b) diffs.add('($tag) $field: ours "$a", pydicom "$b"');
    }
  }
  stdout
    ..writeln(
        'crosscheck vs pydicom: ${ours.length} ours, ${theirs.length} theirs')
    ..writeln('  only ours: ${onlyOurs.length} ${onlyOurs.take(8).join(' ')}')
    ..writeln(
        '  only pydicom: ${onlyTheirs.length} ${onlyTheirs.take(8).join(' ')}')
    ..writeln('  field differences: ${diffs.length}');
  for (final d in diffs.take(20)) {
    stdout.writeln('    $d');
  }
}
