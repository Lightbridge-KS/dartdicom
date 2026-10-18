import 'dart:typed_data';

import '../lut/modality_lut.dart';
import '../lut/voi.dart';

/// [stored] through [modality], then [voi], then (when [invert], for
/// MONOCHROME1) the inversion: one gray byte per value (PRD X-04, X-07).
///
/// Each step depends on the stored value alone, so when the values span at
/// most 16 bits and there are at least as many of them as possible values,
/// every possible value is mapped once into a table, and each pixel is a
/// lookup. Moving a window then costs one table and one pass.
Uint8List toGray(List<int> stored,
    {required ModalityLut modality,
    required Voi voi,
    required bool invert,
    required int bitsStored,
    required bool signed}) {
  int level(int value) {
    final gray = voi.apply(modality.apply(value));
    return invert ? 255 - gray : gray;
  }

  final out = Uint8List(stored.length);
  if (bitsStored <= 16 && stored.length >= 1 << bitsStored) {
    final lowest = signed ? -(1 << (bitsStored - 1)) : 0;
    final table = Uint8List(1 << bitsStored);
    for (var i = 0; i < table.length; i++) {
      table[i] = level(lowest + i);
    }
    for (var i = 0; i < stored.length; i++) {
      out[i] = table[stored[i] - lowest];
    }
    return out;
  }
  for (var i = 0; i < stored.length; i++) {
    out[i] = level(stored[i]);
  }
  return out;
}
