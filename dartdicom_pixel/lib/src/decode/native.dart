import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';

import '../pixel_array/pixel_array.dart';
import '../pixel_array/pixel_module.dart';

/// Decodes frame [index] of uncompressed Pixel Data (PRD X-02): 8 or 16 bits
/// allocated, signed or unsigned, with the bits above Bits Stored masked off
/// and signed values sign-extended (as pydicom's `correct_unused_bits`).
PixelArray decodeNativeFrame(Dataset ds, PixelModule m, int index) {
  final ts = ds.transferSyntax == null
      ? TransferSyntax.explicitVrLittleEndian
      : TransferSyntax.of(ds.transferSyntax!);
  if (ts == null || ts.encapsulated) {
    throw UnsupportedError(
        'compressed Pixel Data (transfer syntax ${ds.transferSyntax?.value}) '
        'needs a codec, which is not supported yet');
  }
  if (m.bitsAllocated != 8 && m.bitsAllocated != 16) {
    throw UnsupportedError(
        'Bits Allocated ${m.bitsAllocated} is not supported yet (8 and 16 are)');
  }
  if (index < 0 || index >= m.numberOfFrames) {
    throw RangeError.range(index, 0, m.numberOfFrames - 1, 'index');
  }
  final bytes = ds.require(DicomTags.pixelData);
  final start = index * m.frameLength;
  if (start + m.frameLength > bytes.length) {
    throw DicomParseException(
        'Pixel Data is shorter than the frames the pixel module declares',
        tag: DicomTags.pixelData);
  }
  final count = m.frameLength * 8 ~/ m.bitsAllocated;
  final absolute = bytes.offsetInBytes + start;
  final unused = m.bitsAllocated - m.bitsStored;

  if (m.bitsAllocated == 8) {
    // 8-bit data in OW, Big Endian: the bytes are in 16-bit words, so each
    // pair is swapped (pydicom's be_swap_ow), across the whole even-length
    // value: an odd image's last pixel comes from its padding word.
    final swapPairs =
        !ts.littleEndian && ds.element(DicomTags.pixelData)?.vr == Vr.OW;
    if (swapPairs) {
      final out = m.signed ? Int8List(count) : Uint8List(count);
      for (var i = 0; i < count; i++) {
        final j = start + (i ^ 1);
        out[i] = _correct(
            bytes[j < bytes.length ? j : start + i], m.bitsStored, m.signed);
      }
      return PixelArray(out, m);
    }
    if (unused == 0) {
      return PixelArray(
          m.signed
              ? Int8List.view(bytes.buffer, absolute, count)
              : Uint8List.view(bytes.buffer, absolute, count),
          m);
    }
    final out = m.signed ? Int8List(count) : Uint8List(count);
    for (var i = 0; i < count; i++) {
      out[i] = _correct(bytes[start + i], m.bitsStored, m.signed);
    }
    return PixelArray(out, m);
  }

  final hostOrder = (Endian.host == Endian.little) == ts.littleEndian;
  if (unused == 0 && hostOrder && absolute.isEven) {
    return PixelArray(
        m.signed
            ? Int16List.view(bytes.buffer, absolute, count)
            : Uint16List.view(bytes.buffer, absolute, count),
        m);
  }
  final data = ByteData.sublistView(bytes, start, start + m.frameLength);
  final endian = ts.littleEndian ? Endian.little : Endian.big;
  final out = m.signed ? Int16List(count) : Uint16List(count);
  for (var i = 0; i < count; i++) {
    out[i] = _correct(data.getUint16(i * 2, endian), m.bitsStored, m.signed);
  }
  return PixelArray(out, m);
}

/// Keeps the low [bitsStored] bits of [raw], sign-extending if [signed].
int _correct(int raw, int bitsStored, bool signed) {
  final masked = raw & ((1 << bitsStored) - 1);
  if (!signed) return masked;
  final sign = 1 << (bitsStored - 1);
  return masked & sign != 0 ? masked - (1 << bitsStored) : masked;
}
