import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';

import '../errors.dart';
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
    throw UnsupportedPixelEncoding(
        'Pixel Data is compressed, or in a transfer syntax this version '
        "doesn't know; it decodes native (uncompressed) syntaxes only: "
        'request an uncompressed transfer syntax',
        transferSyntax: ds.transferSyntax);
  }
  if (m.bitsAllocated != 8 && m.bitsAllocated != 16) {
    throw UnsupportedPixelEncoding('is not one this version decodes (8 or 16)',
        tag: DicomTags.bitsAllocated);
  }
  if (m.photometricInterpretation == 'YBR_FULL_422') {
    throw UnsupportedPixelEncoding(
        'YBR_FULL_422 needs chroma upsampling, which is color support (X-08)',
        tag: DicomTags.photometricInterpretation);
  }
  if (m.planarConfiguration == 1) {
    throw UnsupportedPixelEncoding(
        'is 1 (one plane per sample), which this version does not decode yet',
        tag: DicomTags.planarConfiguration);
  }
  if (index < 0 || index >= m.numberOfFrames) {
    throw RangeError.range(index, 0, m.numberOfFrames - 1, 'index');
  }
  final bytes = _pixelData(ds);
  // Compared before multiplying, so huge declared sizes can't overflow.
  if (m.frameLength > bytes.length || index >= bytes.length ~/ m.frameLength) {
    throw InvalidPixelModule(DicomTags.pixelData,
        'is shorter than the frames the Image Pixel module declares');
  }
  final start = index * m.frameLength;
  final count = m.frameLength * 8 ~/ m.bitsAllocated;
  final absolute = bytes.offsetInBytes + start;
  final unused = m.bitsAllocated - m.bitsStored;

  if (m.bitsAllocated == 8) {
    // 8-bit data in OW, Big Endian: the bytes are in 16-bit words, so each
    // pair is swapped (pydicom's be_swap_ow). The pairs count from the start
    // of the value, so a frame may start on its odd byte, and an odd image's
    // last pixel comes from the padding word.
    final swapPairs =
        !ts.littleEndian && ds.element(DicomTags.pixelData)?.vr == Vr.OW;
    if (swapPairs) {
      final out = m.signed ? Int8List(count) : Uint8List(count);
      for (var i = 0; i < count; i++) {
        final j = (start + i) ^ 1;
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

/// Keeps the low [bitsStored] bits of [raw], sign-extending if [signed].
int _correct(int raw, int bitsStored, bool signed) {
  final masked = raw & ((1 << bitsStored) - 1);
  if (!signed) return masked;
  final sign = 1 << (bitsStored - 1);
  return masked & sign != 0 ? masked - (1 << bitsStored) : masked;
}
