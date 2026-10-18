import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';

import '../errors.dart';
import '../pixel_array/pixel_array.dart';
import '../pixel_array/pixel_module.dart';

/// Decodes [count] frames of uncompressed Pixel Data from frame [first]
/// into one buffer (PRD X-02), as pydicom 3.0.2's `pixel_array` does:
/// - Bits Allocated 1 (unpacked, least significant bit first), 8, 16 or 32;
/// - the bits above Bits Stored masked off, and signed values
///   sign-extended (`correct_unused_bits`);
/// - PlanarConfiguration 1 interleaved, frame by frame;
/// - data wider than 8 bits in the transfer syntax's byte order, and 8-bit
///   OW Big Endian in swapped byte pairs (`be_swap_ow`).
///
/// The result is a zero-copy view of Pixel Data when nothing needs changing
/// and the byte order and alignment allow.
PixelArray decodeNative(Dataset ds, PixelModule m, int first, int count) {
  final ts = ds.transferSyntax == null
      ? TransferSyntax.explicitVrLittleEndian
      : TransferSyntax.of(ds.transferSyntax!);
  if (ts == null || ts.encapsulated) {
    throw UnsupportedPixelEncoding(
        'Pixel Data is compressed, or in a transfer syntax this version '
        "doesn't know; it decodes native (uncompressed) syntaxes only: "
        'request an uncompressed transfer syntax',
        transferSyntax: ds.transferSyntax);
  }
  if (!const {1, 8, 16, 32}.contains(m.bitsAllocated)) {
    throw UnsupportedPixelEncoding(
        'is not one this version decodes (1, 8, 16 or 32)',
        tag: DicomTags.bitsAllocated);
  }
  if (m.photometricInterpretation == 'YBR_FULL_422') {
    throw UnsupportedPixelEncoding(
        'YBR_FULL_422 needs chroma upsampling, which is color support (X-08)',
        tag: DicomTags.photometricInterpretation);
  }
  final last = first + count - 1;
  if (first < 0 || last >= m.numberOfFrames) {
    throw RangeError.range(
        first < 0 ? first : last, 0, m.numberOfFrames - 1, 'index');
  }
  final bytes = _pixelData(ds);
  // Counted in whole frames before multiplying, so a huge declared size
  // can't overflow or allocate.
  final perFrame = m.samplesPerFrame;
  final available = m.bitsAllocated == 1
      ? bytes.length * 8 ~/ perFrame
      : (m.frameLength > bytes.length ? 0 : bytes.length ~/ m.frameLength);
  if (last >= available) {
    throw InvalidPixelModule(DicomTags.pixelData,
        'is shorter than the frames the Image Pixel module declares');
  }

  final samples = count * perFrame;
  final List<int> stored = switch (m.bitsAllocated) {
    1 => _unpackBits(bytes, first * perFrame, samples),
    8 => _bytes(ds, ts, m, bytes, first * m.frameLength, samples),
    16 => _words(ts, m, bytes, first * m.frameLength, samples),
    _ => _longs(ts, m, bytes, first * m.frameLength, samples),
  };
  final values = m.planarConfiguration == 1
      ? _interleave(stored, count, m.rows * m.columns, m.samplesPerPixel)
      : stored;
  return PixelArray(values, m, firstFrame: first);
}

/// The Pixel Data bytes; an [InvalidPixelModule] if there are none.
Uint8List _pixelData(Dataset ds) {
  final Uint8List? bytes;
  try {
    bytes = ds.get(DicomTags.pixelData);
  } on DicomDataException {
    throw InvalidPixelModule(DicomTags.pixelData, 'cannot be read');
  }
  return bytes ??
      (throw InvalidPixelModule(
          DicomTags.pixelData,
          'is absent; a dataset read with stopBeforePixels has none, so '
          'read the file again without it'));
}

/// [count] 1-bit pixels from bit [start]: least significant bit first
/// (PS3.5 §8.1.1), one byte each. `~/` and `%`, not shifts, so offsets past
/// 2³² bits stay right on the web.
Uint8List _unpackBits(Uint8List bytes, int start, int count) {
  final out = Uint8List(count);
  for (var i = 0; i < count; i++) {
    final bit = start + i;
    out[i] = (bytes[bit ~/ 8] >> (bit % 8)) & 1;
  }
  return out;
}

/// 8-bit samples from byte [start].
List<int> _bytes(Dataset ds, TransferSyntax ts, PixelModule m, Uint8List bytes,
    int start, int count) {
  // 8-bit data in OW, Big Endian: the bytes are in 16-bit words, so each
  // pair is swapped (pydicom's be_swap_ow). The pairs count from the start
  // of the value, so a frame may start on its odd byte, and an odd image's
  // last pixel comes from the padding word.
  final swapPairs =
      !ts.littleEndian && ds.element(DicomTags.pixelData)?.vr == Vr.OW;
  final out = m.signed ? Int8List(count) : Uint8List(count);
  if (swapPairs) {
    for (var i = 0; i < count; i++) {
      final j = (start + i) ^ 1;
      out[i] = _correct(
          bytes[j < bytes.length ? j : start + i], m.bitsStored, m.signed);
    }
    return out;
  }
  if (m.bitsStored == 8) {
    final at = bytes.offsetInBytes + start;
    return m.signed
        ? Int8List.view(bytes.buffer, at, count)
        : Uint8List.view(bytes.buffer, at, count);
  }
  for (var i = 0; i < count; i++) {
    out[i] = _correct(bytes[start + i], m.bitsStored, m.signed);
  }
  return out;
}

/// 16-bit samples from byte [start].
List<int> _words(
    TransferSyntax ts, PixelModule m, Uint8List bytes, int start, int count) {
  final at = bytes.offsetInBytes + start;
  if (m.bitsStored == 16 && _hostOrder(ts) && at % 2 == 0) {
    return m.signed
        ? Int16List.view(bytes.buffer, at, count)
        : Uint16List.view(bytes.buffer, at, count);
  }
  final data = ByteData.sublistView(bytes, start, start + count * 2);
  final endian = ts.littleEndian ? Endian.little : Endian.big;
  final out = m.signed ? Int16List(count) : Uint16List(count);
  for (var i = 0; i < count; i++) {
    out[i] = _correct(data.getUint16(i * 2, endian), m.bitsStored, m.signed);
  }
  return out;
}

/// 32-bit samples from byte [start]. Dart on the web has 32-bit shifts, so
/// nothing here shifts by 32: a full 32-bit value comes straight from
/// `getInt32` or `getUint32`, and only narrower ones are masked.
List<int> _longs(
    TransferSyntax ts, PixelModule m, Uint8List bytes, int start, int count) {
  final at = bytes.offsetInBytes + start;
  if (m.bitsStored == 32 && _hostOrder(ts) && at % 4 == 0) {
    return m.signed
        ? Int32List.view(bytes.buffer, at, count)
        : Uint32List.view(bytes.buffer, at, count);
  }
  final data = ByteData.sublistView(bytes, start, start + count * 4);
  final endian = ts.littleEndian ? Endian.little : Endian.big;
  final out = m.signed ? Int32List(count) : Uint32List(count);
  for (var i = 0; i < count; i++) {
    out[i] = m.bitsStored == 32
        ? (m.signed
            ? data.getInt32(i * 4, endian)
            : data.getUint32(i * 4, endian))
        : _correct(data.getUint32(i * 4, endian), m.bitsStored, m.signed);
  }
  return out;
}

bool _hostOrder(TransferSyntax ts) =>
    (Endian.host == Endian.little) == ts.littleEndian;

/// [stored] with each frame's planes (all of sample 0, then 1, then 2)
/// interleaved into pixels, as pydicom returns PlanarConfiguration 1.
List<int> _interleave(List<int> stored, int frames, int pixels, int samples) {
  final out = _like(stored);
  final frameLength = pixels * samples;
  for (var f = 0; f < frames; f++) {
    final base = f * frameLength;
    for (var s = 0; s < samples; s++) {
      for (var p = 0; p < pixels; p++) {
        out[base + p * samples + s] = stored[base + s * pixels + p];
      }
    }
  }
  return out;
}

/// A new typed list of [list]'s type and length.
List<int> _like(List<int> list) => switch (list) {
      Int8List() => Int8List(list.length),
      Uint8List() => Uint8List(list.length),
      Int16List() => Int16List(list.length),
      Uint16List() => Uint16List(list.length),
      Int32List() => Int32List(list.length),
      _ => Uint32List(list.length),
    };

/// Keeps the low [bitsStored] bits of [raw] (at most 31), sign-extending if
/// [signed].
int _correct(int raw, int bitsStored, bool signed) {
  final masked = raw & ((1 << bitsStored) - 1);
  if (!signed) return masked;
  final sign = 1 << (bitsStored - 1);
  return masked & sign != 0 ? masked - (1 << bitsStored) : masked;
}
