// Fuzzing the network decoders (M3 step 10, PRD "untrusted input", I-30):
// the PDU decoder, the framer, the DIMSE assembler, and an established
// requestor fed mutated PDUs. Seeded and deterministic, so a failure names
// the case that reproduces it. Only the documented failures are allowed:
// FormatException from the decoders, DimseProtocolException from the
// assembler, a DimseException from an association.
//
// DARTDICOM_FUZZ_CASES sets the cases per group (`just fuzz` runs more);
// DARTDICOM_FUZZ_SEED moves the starting seed.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dimse/fragments.dart';
import 'package:dartdicom_net/src/dul/framer.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:test/test.dart';

import '../support/peer.dart';

final _env = Platform.environment;
final _cases = int.tryParse(_env['DARTDICOM_FUZZ_CASES'] ?? '') ?? 2000;
final _firstSeed = int.tryParse(_env['DARTDICOM_FUZZ_SEED'] ?? '') ?? 0;

void main() {
  final vectors =
      ((jsonDecode(File('../fixtures/data/net/vectors.json').readAsStringSync())
              as Map<String, Object?>)['vectors']! as List<Object?>)
          .cast<Map<String, Object?>>();
  // Every PDU the vectors hold, DIMSE messages' P-DATA-TFs included.
  final pdus = [
    for (final v in vectors)
      if (v['hex'] case final String hex)
        _hex(hex)
      else
        for (final hex in (v['pdus']! as List<Object?>).cast<String>())
          _hex(hex),
  ];
  final pData = [
    for (final p in pdus)
      if (p[0] == 0x04) p
  ];

  test('Pdu.decode returns a PDU or throws a FormatException', () {
    final failures = <String>[];
    for (var i = 0; i < _cases; i++) {
      final seed = _firstSeed + i;
      final random = Random(seed);
      final (bytes, how) = random.nextInt(5) == 0
          ? (_noise(random, random.nextInt(300)), 'noise')
          : _mutate(pdus[random.nextInt(pdus.length)], random);
      try {
        Pdu.decode(bytes).encode();
      } on FormatException {
        // Malformed: the documented refusal (Evt19).
      } catch (e) {
        failures.add('seed $seed ($how): ${e.runtimeType}: $e');
      }
    }
    expect(failures, isEmpty, reason: failures.take(10).join('\n'));
  });

  test('the framer splits any byte stream or reports a FormatException',
      () async {
    final failures = <String>[];
    for (var i = 0; i < _cases ~/ 4; i++) {
      final seed = _firstSeed + i;
      final random = Random(seed);
      final stream = [
        for (var n = random.nextInt(4) + 1; n > 0; n--)
          ..._mutate(pdus[random.nextInt(pdus.length)], random).$1,
      ];
      // Delivered in random chunks.
      final chunks = <Uint8List>[];
      for (var at = 0; at < stream.length;) {
        final end = min(stream.length, at + 1 + random.nextInt(64));
        chunks.add(Uint8List.fromList(stream.sublist(at, end)));
        at = end;
      }
      try {
        await Stream.fromIterable(chunks)
            .transform(const PduFramer())
            .drain<void>();
      } on FormatException {
        // A length past the cap, or a PDU cut by the end of the stream.
      } catch (e) {
        failures.add('seed $seed: ${e.runtimeType}: $e');
      }
    }
    expect(failures, isEmpty, reason: failures.take(10).join('\n'));
  });

  test('the assembler yields messages or throws a DimseProtocolException', () {
    final failures = <String>[];
    for (var i = 0; i < _cases; i++) {
      final seed = _firstSeed + i;
      final random = Random(seed);
      final assembler = Assembler();
      try {
        for (var n = random.nextInt(4) + 1; n > 0; n--) {
          final (bytes, _) =
              _mutate(pData[random.nextInt(pData.length)], random);
          final Pdu pdu;
          try {
            pdu = Pdu.decode(bytes);
          } on FormatException {
            continue; // the DUL's to refuse, not the assembler's
          }
          if (pdu is PDataTf) assembler.feed(pdu);
        }
      } on DimseProtocolException {
        // The documented refusal.
      } catch (e) {
        failures.add('seed $seed: ${e.runtimeType}: $e');
      }
    }
    expect(failures, isEmpty, reason: failures.take(10).join('\n'));
  });

  test('an established requestor fed mutated PDUs only fails as DIMSE',
      () async {
    final failures = <String>[];
    for (var i = 0; i < _cases ~/ 20; i++) {
      final seed = _firstSeed + i;
      final random = Random(seed);
      final failure = await _feedRequestor([
        for (var n = random.nextInt(3) + 1; n > 0; n--)
          _mutate(pdus[random.nextInt(pdus.length)], random).$1,
      ], random.nextBool());
      if (failure != null) failures.add('seed $seed: $failure');
    }
    expect(failures, isEmpty, reason: failures.take(10).join('\n'));
  }, timeout: const Timeout(Duration(minutes: 30)));
}

/// Associates, starts a C-ECHO (or not), and lets the peer send [junk], in
/// real time with short timers (fake time can't see streams close). Returns
/// why that went wrong in a way it mustn't (a non-DIMSE error, an unhandled
/// one, or a C-ECHO that never ends), or null.
Future<String?> _feedRequestor(List<Uint8List> junk, bool echo) async {
  String? failure;
  final finished = Completer<void>();
  unawaited(runZonedGuarded(() async {
    try {
      final (ours, peer) = ScriptedPeer.connect();
      unawaited(peer.accept().then((_) {}, onError: (Object _) {}));
      final assoc = await const ApplicationEntity(
              aeTitle: 'SCU',
              requestedContexts: PresentationContexts.verification,
              timeouts: Timeouts(
                  acse: Duration(milliseconds: 50),
                  dimse: Duration(milliseconds: 50),
                  network: Duration(milliseconds: 200)))
          .associateOver(ours, aeTitle: 'PEER');
      final pending = echo ? assoc.sendCEcho() : null;
      for (final bytes in junk) {
        await peer.transport.send(bytes).then((_) {}, onError: (Object _) {});
      }
      if (pending != null) {
        try {
          await pending.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          failure = 'the C-ECHO never ended';
        } on DimseException {
          // The documented way for it to fail.
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await assoc.abort();
    } on Object catch (e) {
      failure ??= '${e.runtimeType}: $e';
    } finally {
      finished.complete();
    }
  }, (Object e, StackTrace _) {
    failure ??= 'an unhandled ${e.runtimeType}: $e';
  }));
  await finished.future;
  return failure;
}

(Uint8List, String) _mutate(Uint8List source, Random random) {
  final bytes = Uint8List.fromList(source);
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
      // A length field rewritten: the PDU's, or a sub-item's.
      const values = [0, 1, 2, 5, 0xFF, 0xFFFF, 0x7FFFFFFF, 0xFFFFFFFF];
      final value = values[random.nextInt(values.length)];
      final at = random.nextBool() ? 2 : random.nextInt(bytes.length);
      final width = random.nextBool() ? 2 : 4;
      for (var i = 0; i < width && at + i < bytes.length; i++) {
        bytes[at + i] = value >> (8 * (width - 1 - i)) & 0xFF; // big-endian
      }
      return (bytes, '$width-byte length at $at set to $value');
    default:
      final at = random.nextInt(bytes.length);
      final tail = _noise(random, random.nextInt(48));
      return (
        Uint8List.fromList([...bytes.sublist(0, at), ...tail]),
        '${tail.length} random bytes from $at'
      );
  }
}

Uint8List _noise(Random random, int n) =>
    Uint8List.fromList([for (var i = 0; i < n; i++) random.nextInt(256)]);

Uint8List _hex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
