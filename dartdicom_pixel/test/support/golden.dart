// pydicom's goldens, as the pixel tests read them (VM only: they use files
// and the environment).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartdicom/dartdicom.dart';
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

/// One file's LUT golden (blueprint F47): pydicom's output frame by frame,
/// or the [error] it raised decoding the file.
typedef LutGolden = ({String file, String? error, List<LutFrame> frames});

/// One frame of a [LutGolden]: the SHA-256 of pydicom's modality values,
/// and its VOI variants.
typedef LutFrame = ({String modality, List<VoiVariant> voi});

/// One VOI of a frame: a LUT or a window ([kind]) by [index], and pydicom's
/// output rescaled to 0–255 ([gray]), or the [error] it raised instead.
typedef VoiVariant = ({String kind, int index, String? error, Uint8List? gray});

/// The LUT goldens under [root], sorted by file: the one reader of their
/// JSON.
List<LutGolden> lutGoldens(Directory root) => [
      for (final file
          in root
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
        _golden(jsonDecode(file.readAsStringSync()) as Map<String, Object?>),
    ];

LutGolden _golden(Map<String, Object?> record) => (
      file: record['file']! as String,
      error: record['error'] as String?,
      frames: [
        for (final frame in (record['frames'] as List<Object?>? ?? const [])
            .cast<Map<String, Object?>>())
          (
            modality: frame['modality']! as String,
            voi: [
              for (final v in (frame['voi']! as List<Object?>)
                  .cast<Map<String, Object?>>())
                (
                  kind: v['kind']! as String,
                  index: v['index']! as int,
                  error: v['error'] as String?,
                  gray: switch (v['gray']) {
                    final String gray => base64Decode(gray),
                    _ => null,
                  },
                ),
            ],
          ),
      ],
    );

/// The first way [golden]'s frames disagree with dartdicom's, frame by
/// frame: its modality values, then each VOI variant ([voiMismatch]).
/// `null` when every frame agrees. [ds] is the file's dataset.
String? lutMismatch(Dataset ds, LutGolden golden) {
  final px = ds.pixels;
  for (final (f, expected) in golden.frames.indexed) {
    final frame = px.frame(f);
    if (modalitySha(frame.toModality()) != expected.modality) {
      return 'frame $f: modality values differ';
    }
    for (final variant in expected.voi) {
      if (voiMismatch(ds, frame, variant) case final problem?) {
        return 'frame $f, ${variant.kind} ${variant.index}: $problem';
      }
    }
  }
  return null;
}

/// The SHA-256 of [values] as float64, little endian: how the LUT goldens
/// hash pydicom's `apply_modality_lut` output.
String modalitySha(Float64List values) {
  final data = ByteData(values.length * 8);
  for (final (i, v) in values.indexed) {
    data.setFloat64(i * 8, v, Endian.little);
  }
  return sha256.convert(data.buffer.asUint8List()).toString();
}

/// One VOI variant of a LUT golden against dartdicom (I-33): `null` when
/// every pixel of [frame]'s display is within one gray level of pydicom's
/// `apply_voi_lut` (rescaled to 0–255, before MONOCHROME1's inversion),
/// else what differs. [ds] is the dataset [frame] came from.
String? voiMismatch(Dataset ds, PixelArray frame, VoiVariant variant) {
  final (:kind, :index, :error, :gray) = variant;
  // No output range to rescale pydicom's values by: nothing to compare.
  if (error == 'ZeroDivisionError') return null;
  final Voi? voi;
  final DisplayBuffer buffer;
  try {
    voi =
        ds.voi(frame: frame.firstFrame, index: index, preferLut: kind == 'lut');
    buffer = frame.toDisplay(voi);
  } on PixelDataException catch (e) {
    return error == null
        ? 'refused, where pydicom did not: ${e.message}'
        : null;
  } on RangeError {
    return error == null ? 'a RangeError, where pydicom had none' : null;
  }
  // pydicom refuses bits per entry other than 8 or 10–16; dartdicom takes
  // 8–16, so only that refusal may go unmatched.
  if (error != null) {
    return error == 'NotImplementedError' ? null : 'pydicom raised $error';
  }
  if ((kind == 'lut') != (voi is VoiLut)) {
    return 'chose ${voi.runtimeType} for a $kind';
  }
  final expected = gray!;
  final invert = frame.module.photometricInterpretation == 'MONOCHROME1';
  var worst = 0;
  for (var i = 0; i < expected.length; i++) {
    final gray = invert ? 255 - buffer.gray[i] : buffer.gray[i];
    final off = (gray - expected[i]).abs();
    if (off > worst) worst = off;
  }
  return worst <= 1 ? null : 'a pixel is $worst gray levels off';
}
