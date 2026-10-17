// Fuzzing (M2 step 7): the parser, the inflater and the force path on
// mutated fixtures. Seeded and deterministic, so a failure names the case
// that reproduces it. Reading may give a result or a DicomParseException,
// writing a DicomWriteException; anything else is a bug.
//
// DARTDICOM_FUZZ_CASES sets the number of cases per group (`just fuzz` runs
// more); DARTDICOM_FUZZ_SEED moves the starting seed.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/io.dart';
import 'package:test/test.dart';

final _env = Platform.environment;
final _cases = int.tryParse(_env['DARTDICOM_FUZZ_CASES'] ?? '') ?? 2000;
final _firstSeed = int.tryParse(_env['DARTDICOM_FUZZ_SEED'] ?? '') ?? 0;

/// Inflated sizes past this are refused, so a mutated stream can't make a
/// case slow (the parser's own bound is 1 GiB).
const _maxInflated = 1 << 24;

final class _Capped implements DeflateCodec {
  const _Capped();

  @override
  Uint8List inflate(Uint8List data, {int maxLength = _maxInflated}) =>
      const PureDartInflate().inflate(data, maxLength: maxLength);

  @override
  Uint8List deflate(Uint8List data) => throw UnimplementedError();
}

void main() {
  // The small fixtures: every syntax the reader knows, sequences, private
  // tags, charsets, encapsulated and Deflated data.
  final seeds = [
    for (final dir in ['synthetic', 'pydicom'])
      ...Directory('../fixtures/data/$dir')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dcm') && f.lengthSync() < 10000),
  ]..sort((a, b) => a.path.compareTo(b.path));
  final seedBytes = [for (final f in seeds) f.readAsBytesSync()];
  final seedNames = [for (final f in seeds) f.uri.pathSegments.last];

  test('mutated files read or fail with a DicomParseException', () {
    final failures = <String>[];
    final outcomes = _Outcomes();
    for (var i = 0; i < _cases; i++) {
      final seed = _firstSeed + i;
      final random = Random(seed);
      final pick = random.nextInt(seedBytes.length);
      final (bytes, how) = _mutate(seedBytes[pick], random);
      final failure = _read(bytes, outcomes, force: false);
      if (failure != null) {
        failures.add('seed $seed (${seedNames[pick]}, $how): $failure');
      }
    }
    print('mutated: $outcomes');
    expect(failures, isEmpty, reason: failures.take(10).join('\n'));
  });

  test('the force path reads what is left without a preamble or meta', () {
    final failures = <String>[];
    final outcomes = _Outcomes();
    for (var i = 0; i < _cases; i++) {
      final seed = _firstSeed + i;
      final random = Random(seed);
      final pick = random.nextInt(seedBytes.length);
      final source = seedBytes[pick];
      // Drop the preamble, or everything up to a random point in the meta
      // or dataset, then maybe mutate what is left.
      final cut = random.nextBool()
          ? 128 + 4
          : 132 + random.nextInt(max(1, source.length - 132));
      var bytes = Uint8List.sublistView(source, min(cut, source.length));
      var how = 'cut at $cut';
      if (random.nextBool()) {
        final (mutated, more) = _mutate(bytes, random);
        bytes = mutated;
        how = '$how, $more';
      }
      final failure = _read(bytes, outcomes, force: true);
      if (failure != null) {
        failures.add('seed $seed (${seedNames[pick]}, $how): $failure');
      }
    }
    print('force: $outcomes');
    expect(failures, isEmpty, reason: failures.take(10).join('\n'));
  });

  test('the inflater returns bytes or throws a FormatException', () {
    final deflated = [
      for (final (i, bytes) in seedBytes.indexed)
        if (DicomFile.fromBytes(bytes).meta.transferSyntaxUid ==
            TransferSyntaxes.deflatedExplicitVrLittleEndian)
          _body(seedBytes[i]),
    ];
    expect(deflated, isNotEmpty);
    final failures = <String>[];
    for (var i = 0; i < _cases; i++) {
      final seed = _firstSeed + i;
      final random = Random(seed);
      // Mutated real streams, and pure noise.
      final (bytes, how) = random.nextInt(4) == 0
          ? (_noise(random, random.nextInt(256)), 'noise')
          : _mutate(deflated[random.nextInt(deflated.length)], random);
      try {
        const _Capped().inflate(bytes);
      } on FormatException {
        // Malformed: the expected refusal.
      } catch (e) {
        failures.add('seed $seed ($how): ${e.runtimeType}: $e');
      }
    }
    expect(failures, isEmpty, reason: failures.take(10).join('\n'));
  });
}

/// How the cases of a group ended.
final class _Outcomes {
  var read = 0;
  var written = 0;
  var refused = 0;

  @override
  String toString() => '$read read ($written written), $refused refused';
}

/// Reads [bytes], touches every value, and writes the result; returns why
/// that failed in a way it mustn't, or null.
String? _read(Uint8List bytes, _Outcomes outcomes, {required bool force}) {
  try {
    final file = DicomFile.fromBytes(bytes,
        options: ReadOptions(force: force, deflateCodec: const _Capped()));
    _touch(file.meta.dataset);
    _touch(file.dataset);
    file.report.summary();
    file.toString();
    outcomes.read++;
    try {
      file.toBytes(
          options: const WriteOptions(deflateCodec: ZLibDeflateCodec()));
      outcomes.written++;
    } on DicomWriteException {
      // Refused: partial, missing UIDs, unencodable values.
    }
  } on DicomParseException {
    // The expected refusal of malformed data.
    outcomes.refused++;
  } catch (e, stack) {
    final frame = stack
        .toString()
        .split('\n')
        .firstWhere((l) => l.contains('package:dartdicom/'), orElse: () => '');
    return '${e.runtimeType}: $e ${frame.trim()}';
  }
  return null;
}

void _touch(Dataset ds) {
  ds.toString();
  for (final e in ds.elements) {
    e.toString();
    final value = e.value;
    if (value is Sequence) value.forEach(_touch);
  }
}

/// One mutation of [source], and what it was.
(Uint8List, String) _mutate(Uint8List source, Random random) {
  final bytes = Uint8List.fromList(source);
  if (bytes.isEmpty) return (bytes, 'empty');
  switch (random.nextInt(4)) {
    case 0:
      final flips = 1 + random.nextInt(8);
      for (var i = 0; i < flips; i++) {
        bytes[random.nextInt(bytes.length)] ^= 1 << random.nextInt(8);
      }
      return (bytes, '$flips bit flips');
    case 1:
      final at = random.nextInt(bytes.length);
      return (Uint8List.sublistView(bytes, 0, at), 'truncated at $at');
    case 2:
      // A length rewritten: a 16- or 32-bit word set to a value parsers
      // trip on.
      const values = [
        0, 1, 2, 7, 0xFF, 0xFFFF, 0x7FFFFFFF, 0xFFFFFFFE, //
        0xFFFFFFFF
      ];
      final value = values[random.nextInt(values.length)];
      final at = random.nextInt(bytes.length) & ~1;
      final width = random.nextBool() ? 2 : 4;
      for (var i = 0; i < width && at + i < bytes.length; i++) {
        bytes[at + i] = value >> (8 * i) & 0xFF;
      }
      return (bytes, '$width-byte word at $at set to $value');
    default:
      final at = random.nextInt(bytes.length);
      final tail = _noise(random, random.nextInt(64));
      return (
        Uint8List.fromList([...bytes.sublist(0, at), ...tail]),
        '${tail.length} random bytes from $at'
      );
  }
}

Uint8List _noise(Random random, int n) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) random.nextInt(256)]);

/// The raw DEFLATE body of a Deflated Part 10 file: everything after the
/// meta.
Uint8List _body(Uint8List file) {
  final meta = ByteData.sublistView(file, 140, 144).getUint32(0, Endian.little);
  return Uint8List.sublistView(file, 144 + meta);
}
