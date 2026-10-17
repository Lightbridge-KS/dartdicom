// Compares our reading of a file with pydicom's golden record (I-11), for
// the committed fixtures and the cached corpus alike. Collects mismatches
// instead of failing on the first, so a corpus run reports every file.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartdicom/dartdicom.dart';

/// One comparison's findings: mismatches, and the named tolerances that
/// excused a difference. A tolerance is a documented pydicom quirk, never a
/// file name, and exists only while the corpus needs it (none yet).
final class GoldenCompare {
  final mismatches = <String>[];
  final tolerated = <String, int>{};

  /// Compares [file] with [record], a golden JSON record.
  void file(Map<String, Object?> record, DicomFile file) {
    elements(record['meta']! as List<Object?>, file.meta.dataset, 'meta');
    elements(record['dataset']! as List<Object?>, file.dataset, '');
  }

  void elements(List<Object?> golden, Dataset ds, String where) {
    final theirs = {
      for (final g in golden.cast<Map<String, Object?>>())
        g['tag']! as String: g,
    };
    final ours = {for (final e in ds.elements) _hex(e.tag): e};
    for (final tag in theirs.keys.where((t) => !ours.containsKey(t))) {
      mismatches.add('$where $tag: missing');
    }
    for (final tag in ours.keys.where((t) => !theirs.containsKey(t))) {
      mismatches.add('$where $tag: extra');
    }
    for (final MapEntry(key: tag, value: g) in theirs.entries) {
      final e = ours[tag];
      if (e != null) _element(g, e, '$where $tag');
    }
  }

  void _element(Map<String, Object?> g, DataElement e, String at) {
    if (e.vr.code != g['vr']) {
      mismatches.add('$at: VR ${e.vr.code}, pydicom ${g['vr']}');
      return;
    }
    final Object value;
    try {
      value = e.value;
    } on DicomParseException catch (error) {
      mismatches.add('$at: ${error.message}');
      return;
    }
    _value(g['value'], value, at);
  }

  void _value(Object? golden, Object ours, String at) {
    switch (ours) {
      case Sequence():
        final items =
            ((golden as Map?)?['items'] as List<Object?>?) ?? const [];
        if (items.length != ours.length) {
          mismatches.add('$at: ${ours.length} items, pydicom ${items.length}');
          return;
        }
        for (final (i, item) in ours.indexed) {
          elements(items[i]! as List<Object?>, item, '$at[$i]');
        }
      case Uint8List():
        final g = golden as Map?;
        final ok = g == null
            ? ours.isEmpty
            : g.containsKey('bytes')
                ? _hexBytes(ours) == g['bytes']
                : ours.length == g['bytes_len'] &&
                    sha256.convert(ours).toString() == g['sha256'];
        if (!ok) mismatches.add('$at: bytes differ');
      case List():
        final plain = ours.map(_plain).toList();
        final ok = switch (plain.length) {
          0 => golden == '' ||
              golden == null ||
              (golden is List && golden.isEmpty),
          1 => _same(plain.single, golden),
          _ => _same(plain, golden),
        };
        if (!ok) mismatches.add('$at: value differs');
    }
  }
}

/// Deep equality over JSON-shaped values.
bool _same(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Our value as pydicom's golden JSON spells it.
Object? _plain(Object? v) => switch (v) {
      final BigInt b => b.toInt(),
      final Tag t => t.value,
      _ => v,
    };

String _hex(Tag t) => t.value.toRadixString(16).padLeft(8, '0').toUpperCase();

String _hexBytes(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
