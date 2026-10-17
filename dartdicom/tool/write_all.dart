// The written-file gate's first half (M2 step 6, PRD C-11): reads every
// .dcm under the given roots and writes each into the transfer syntaxes it
// can be written in, asserting the refusals F41 promises for the rest.
// pydicom, DCMTK and test/gates/written_test.dart then read what it wrote.
//
//   dart run tool/write_all.dart --out <dir> <root>[=<golden root>] ...
//
// Writes <dir>/<root name>/<path without .dcm>/<target>.dcm and
// <dir>/manifest.json. A golden root (pydicom's reading of the sources)
// lets the test compare pixel arrays (I-18). Exits 1 if a write fails where
// it should succeed, or succeeds where it should be refused.
import 'dart:convert';
import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/io.dart';
import 'package:dartdicom/src/dataset/dataset.dart' show isPartial;

/// The targets: `as_read` keeps the source's syntax; the rest name one.
const _targets = {
  'as_read': null,
  'implicit': TransferSyntaxes.implicitVrLittleEndian,
  'explicit': TransferSyntaxes.explicitVrLittleEndian,
  'deflated': TransferSyntaxes.deflatedExplicitVrLittleEndian,
};

void main(List<String> args) {
  final outAt = args.indexOf('--out');
  if (outAt < 0 || outAt + 1 >= args.length || args.length < 3) {
    stderr.writeln(
        'usage: dart run tool/write_all.dart --out <dir> <root>[=<golden>] ...');
    exit(2);
  }
  final out = Directory(args[outAt + 1])..createSync(recursive: true);
  final roots = [
    for (final (i, a) in args.indexed)
      if (i != outAt && i != outAt + 1) a,
  ];

  final entries = <Map<String, Object?>>[];
  final problems = <String>[];
  for (final spec in roots) {
    final [root, ...golden] = spec.split('=');
    final rootDir = Directory(root);
    final name = rootDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final sources = rootDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dcm') && !f.path.contains('/.git/'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final source in sources) {
      final relative = source.path.substring(rootDir.path.length + 1);
      final stem = relative.substring(0, relative.length - 4);
      final DicomFile file;
      try {
        file = DicomFile.fromBytes(source.readAsBytesSync(),
            options: const ReadOptions(force: true));
      } on DicomParseException {
        continue; // unreadable: the corpus test covers it
      }
      final sourceTs = _syntaxOf(file);
      for (final MapEntry(key: target, value: uid) in _targets.entries) {
        // A target that is the source's syntax is `as_read` already.
        if (uid != null && uid == sourceTs.uid) continue;
        final ts = uid == null ? sourceTs : TransferSyntax.of(uid)!;
        final expected =
            _expectedRefusal(file, sourceTs, ts, asRead: uid == null);
        final entry = <String, Object?>{
          'source': source.absolute.path,
          'relative': '$name/$relative',
          if (golden.isNotEmpty)
            'source_golden': File('${golden.single}/$stem.json').absolute.path,
          'target': target,
          'transfer_syntax': ts.uid.value,
        };
        try {
          final bytes = file.toBytes(
              options: WriteOptions(
                  transferSyntax: uid, deflateCodec: const ZLibDeflateCodec()));
          if (expected != null) {
            problems.add('$name/$relative → $target: written, but should be '
                'refused ($expected)');
            continue;
          }
          final written = File('${out.path}/$name/$stem/$target.dcm')
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(bytes);
          entry['written'] = written.absolute.path;
        } on DicomWriteException catch (e) {
          if (expected == null) {
            problems.add('$name/$relative → $target: refused: ${e.message}');
            continue;
          }
          entry['refused'] = expected;
        }
        entries.add(entry);
      }
    }
  }
  File('${out.path}/manifest.json')
      .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(entries));
  final written = entries.where((e) => e.containsKey('written')).length;
  stdout.writeln('wrote $written files, ${entries.length - written} refused '
      'as expected, into ${out.path}');
  if (problems.isNotEmpty) {
    problems.forEach(stderr.writeln);
    exit(1);
  }
}

/// The syntax [file] was read in: the meta's, else the one detected.
TransferSyntax _syntaxOf(DicomFile file) =>
    TransferSyntax.of(
        file.meta.transferSyntaxUid ?? file.dataset.transferSyntax!) ??
    TransferSyntax.explicitVrLittleEndian;

/// Why writing [file] in [ts] must be refused, or null if it must succeed.
String? _expectedRefusal(
    DicomFile file, TransferSyntax source, TransferSyntax ts,
    {required bool asRead}) {
  if (isPartial(file.dataset)) return 'a partial read';
  final meta = file.meta.dataset;
  final ds = file.dataset;
  for (final (metaTag, tag) in [
    (DicomTags.mediaStorageSopClassUid, DicomTags.sopClassUid),
    (DicomTags.mediaStorageSopInstanceUid, DicomTags.sopInstanceUid),
  ]) {
    final (inMeta, inDataset) = (meta.get(metaTag), ds.get(tag));
    if (inMeta == null && inDataset == null) return 'no SOP UID (data §5)';
    if (inMeta != null && inDataset != null && inMeta != inDataset) {
      return 'contradicting SOP UIDs (I-17)';
    }
  }
  if (asRead && !source.littleEndian) return 'Big Endian is read-only (C-08)';
  if (ds.contains(DicomTags.pixelData) &&
      source.encapsulated != ts.encapsulated) {
    return 'encapsulated and native Pixel Data';
  }
  return null;
}
