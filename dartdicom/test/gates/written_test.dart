// The written-file gate's second half (M2 step 6, PRD C-11): every file
// tool/write_all.dart wrote must read in pydicom as it does in dartdicom
// (I-11 on written files), hold what its source held in the new encoding,
// give pydicom the source's pixel array (I-18), and make DCMTK raise
// nothing the source didn't. Run by scripts/written_gate.sh, which sets
// DARTDICOM_WRITTEN; skipped without it.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/src/dataset/element.dart';
import 'package:dartdicom/src/write/writer.dart' show swapWords;
import 'package:test/test.dart';

import '../support/f41.dart' show contentRepairs;
import '../support/golden.dart';
import 'expected.dart';

void main() {
  final dir = Platform.environment['DARTDICOM_WRITTEN'];
  if (dir == null) {
    test('written files', () {}, skip: 'run by scripts/written_gate.sh');
    return;
  }
  final manifest = (jsonDecode(File('$dir/manifest.json').readAsStringSync())
          as List<Object?>)
      .cast<Map<String, Object?>>();
  final dcmdump = _Dcmdump.find();

  for (final entry in manifest.where((e) => e.containsKey('written'))) {
    test('${entry['relative']} → ${entry['target']}', () {
      final problems = _check(entry, dcmdump);
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }
}

List<String> _check(Map<String, Object?> entry, _Dcmdump? dcmdump) {
  final problems = <String>[];
  final written = entry['written']! as String;
  final record = jsonDecode(
      File(written.replaceFirst(RegExp(r'\.dcm$'), '.json'))
          .readAsStringSync()) as Map<String, Object?>;
  if (record['error'] != null) return ['pydicom: ${record['error']}'];
  if (record['force'] == true) problems.add('pydicom needed force');
  if (record['transfer_syntax'] != entry['transfer_syntax']) {
    problems.add('meta says ${record['transfer_syntax']}');
  }

  final source = DicomFile.fromBytes(
      File(entry['source']! as String).readAsBytesSync(),
      options: const ReadOptions(force: true));
  final file = DicomFile.fromBytes(File(written).readAsBytesSync());
  final left = [
    for (final r in file.report.repairs)
      if (!contentRepairs.contains(r.kind)) r,
  ];
  if (left.isNotEmpty) problems.add('reads with $left');

  // pydicom reads what we wrote as we do (I-11).
  final compare = GoldenCompare()..file(record, file);
  problems.addAll(compare.mismatches.map((m) => 'I-11: $m'));

  // It holds what the source held.
  _Equivalence(file.dataset.transferSyntax!)
      .datasets(source.dataset, file.dataset, '', problems);

  // pydicom decodes the source's pixels from it (I-18).
  final sourceGolden = entry['source_golden'] as String?;
  if (sourceGolden != null && File(sourceGolden).existsSync()) {
    final theirs = (jsonDecode(File(sourceGolden).readAsStringSync())
        as Map<String, Object?>)['pixels'] as Map<String, Object?>?;
    final ours = record['pixels'] as Map<String, Object?>?;
    if (theirs != null &&
        theirs['error'] == null &&
        ours?['sha256'] != theirs['sha256']) {
      problems.add('I-18: pixels ${ours?['error'] ?? 'differ'}');
    }
  }

  if (dcmdump != null) {
    final before = dcmdump.messages(entry['source']! as String);
    for (final m in dcmdump.messages(written)) {
      if (!before.contains(m) && !dcmdump.allowed(m)) {
        problems.add('dcmdump: $m');
      }
    }
  }
  return problems;
}

/// What a source holds, compared with what was written from it in
/// [written]: the same elements and values, with the differences a change
/// of encoding brings. Group lengths are left out (the writer drops stale
/// ones); byte-ordered bytes are swapped when the byte order changed; and
/// where an Implicit VR file gave an element another VR, its bytes are
/// read back in the source's VR.
final class _Equivalence {
  _Equivalence(this.written);

  final Uid written;

  void datasets(Dataset source, Dataset out, String at, List<String> problems) {
    bool kept(DataElement e) => e.tag.element != 0x0000;
    final theirs = {for (final e in source.elements.where(kept)) e.tag: e};
    final ours = {for (final e in out.elements.where(kept)) e.tag: e};
    for (final tag in theirs.keys) {
      if (!ours.containsKey(tag)) problems.add('$at ${describeTag(tag)} lost');
    }
    for (final tag in ours.keys) {
      if (!theirs.containsKey(tag)) problems.add('$at ${describeTag(tag)} new');
    }
    for (final MapEntry(key: tag, value: s) in theirs.entries) {
      if (ours[tag] case final w?) {
        _element(source, s, w, '$at ${describeTag(tag)}', problems);
      }
    }
  }

  void _element(Dataset source, DataElement s, DataElement w, String at,
      List<String> problems) {
    final sv = s.value;
    if (sv is Sequence) {
      final wv = w.value;
      if (wv is! Sequence || wv.length != sv.length) {
        problems.add('$at: items differ');
        return;
      }
      for (var i = 0; i < sv.length; i++) {
        datasets(sv[i], wv[i], '$at[$i]', problems);
      }
      return;
    }
    // In the source's VR: an Implicit VR file can give an element another.
    final raw = rawValueOf(w)!;
    final wv = s.vr == w.vr
        ? w.value
        : readElement(
                s.tag,
                s.vr,
                RawValue(raw.bytes,
                    undefinedLength: raw.undefinedLength,
                    littleEndian: raw.littleEndian,
                    specificCharacterSet: raw.specificCharacterSet))
            .value;
    final expected = sv is Uint8List && _swaps(source, s)
        ? swapWords(sv, _wordSize(source, s))
        : sv;
    final matcher = equals(expected);
    if (!matcher.matches(wv, <Object?, Object?>{})) {
      problems.add('$at: value differs (VR ${s.vr.code} → ${w.vr.code})');
    }
  }

  bool _swaps(Dataset source, DataElement s) {
    final from = TransferSyntax.of(source.transferSyntax!)!;
    final to = TransferSyntax.of(written)!;
    return from.littleEndian != to.littleEndian &&
        const {Vr.OW, Vr.OF, Vr.OL, Vr.OD, Vr.OV}.contains(s.vr);
  }

  int _wordSize(Dataset source, DataElement s) => switch (s.vr) {
        Vr.OW when s.tag == DicomTags.pixelData =>
          (source.get(DicomTags.bitsAllocated) ?? 16) > 16
              ? source.get(DicomTags.bitsAllocated)! ~/ 8
              : 2,
        Vr.OF || Vr.OL => 4,
        Vr.OD || Vr.OV => 8,
        _ => 2,
      };
}

/// DCMTK's `dcmdump`: the warnings and errors it raises on a file. Required
/// where `CI` is set; skipped locally if it isn't installed.
final class _Dcmdump {
  _Dcmdump(this.version, this._allowed);

  static _Dcmdump? find() {
    final ProcessResult result;
    try {
      result = Process.runSync('dcmdump', ['--version'],
          stdoutEncoding: latin1, stderrEncoding: latin1);
    } on ProcessException {
      if (Platform.environment.containsKey('CI')) {
        fail('dcmdump is required in CI (apt-get install dcmtk)');
      }
      printOnFailure('dcmdump not installed: the DCMTK check is skipped');
      return null;
    }
    final version =
        RegExp(r'v(\d+\.\d+\.\d+)').firstMatch('${result.stdout}')?.group(1) ??
            'unknown';
    final allowed = [
      for (final entry in dcmdumpAllowlist)
        if (version.startsWith(entry.dcmtk)) RegExp(entry.pattern),
    ];
    return _Dcmdump(version, allowed);
  }

  final String version;
  final List<RegExp> _allowed;

  /// The `E:` and `W:` lines dcmdump prints for [path]; an exit code that
  /// isn't 0 is one too.
  Set<String> messages(String path) {
    // DCMTK prints text in the file's own character set; Latin-1 decodes
    // any byte.
    final result = Process.runSync('dcmdump', [path],
        stdoutEncoding: latin1, stderrEncoding: latin1);
    return {
      for (final line in LineSplitter.split('${result.stderr}'))
        if (line.startsWith('E: ') || line.startsWith('W: ')) line,
      if (result.exitCode != 0) 'exit ${result.exitCode}',
    };
  }

  bool allowed(String message) => _allowed.any((r) => r.hasMatch(message));
}
