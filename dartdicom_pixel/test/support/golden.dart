// pydicom's goldens, as the pixel tests read them (VM only: they use files
// and the environment).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';

/// [values] as little-endian bytes of [dtype], as pydicom's golden hashes
/// them.
Uint8List leBytes(List<int> values, PixelDtype dtype) {
  final data = ByteData(values.length * dtype.bits ~/ 8);
  for (final (i, v) in values.indexed) {
    switch (dtype.bits) {
      case 8:
        data.setUint8(i, v & 0xFF);
      case 16:
        data.setUint16(i * 2, v & 0xFFFF, Endian.little);
      default:
        data.setUint32(i * 4, v & 0xFFFFFFFF, Endian.little);
    }
  }
  return data.buffer.asUint8List();
}

/// pydicom's shape: frames only when there are several, samples only for
/// color.
List<int> pydicomShape(PixelShape s) => [
      if (s.frames > 1) s.frames,
      s.rows,
      s.columns,
      if (s.samples > 1) s.samples,
    ];

/// The user cache the corpora and their goldens live in, as the fixtures
/// CLI finds it (blueprint §3); core's corpus gate has its own copy, since
/// pixel can't import core's test support.
String cacheRoot() {
  final env = Platform.environment;
  if (env['DARTDICOM_CACHE'] case final root?) return root;
  if (env['XDG_CACHE_HOME'] case final xdg?) return '$xdg/dartdicom';
  return '${env['HOME']}/.cache/dartdicom';
}

/// The LUT goldens under [root] (blueprint F47), sorted by file.
List<Map<String, Object?>> lutRecords(Directory root) => [
      for (final file
          in root
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
    ];

/// The SHA-256 of [values] as float64, little endian: how the LUT goldens
/// hash pydicom's `apply_modality_lut` output.
String modalitySha(Float64List values) {
  final data = ByteData(values.length * 8);
  for (final (i, v) in values.indexed) {
    data.setFloat64(i * 8, v, Endian.little);
  }
  return sha256.convert(data.buffer.asUint8List()).toString();
}
