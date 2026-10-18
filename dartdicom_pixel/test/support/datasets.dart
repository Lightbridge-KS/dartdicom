// In-memory datasets for the pixel tests. No files, so these tests run on
// every platform, node and Chrome included.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';

/// A one-row, 16-bit grayscale image of [values].
Dataset image16(List<int> values,
    {bool signed = true,
    String photometric = 'MONOCHROME2',
    double? slope,
    double? intercept,
    int? padding}) {
  final bytes = ByteData(values.length * 2);
  for (final (i, v) in values.indexed) {
    bytes.setInt16(i * 2, v, Endian.little);
  }
  final ds = Dataset()
    ..set(DicomTags.samplesPerPixel, 1)
    ..set(DicomTags.photometricInterpretation, photometric)
    ..set(DicomTags.rows, 1)
    ..set(DicomTags.columns, values.length)
    ..set(DicomTags.bitsAllocated, 16)
    ..set(DicomTags.bitsStored, 16)
    ..set(DicomTags.pixelRepresentation, signed ? 1 : 0)
    ..set(DicomTags.pixelData, bytes.buffer.asUint8List());
  if (slope != null) ds.set(DicomTags.rescaleSlope, slope);
  if (intercept != null) ds.set(DicomTags.rescaleIntercept, intercept);
  if (padding != null) ds.set(DicomTags.pixelPaddingValue, padding);
  return ds;
}

/// An element as encoded: its tag, VR, and value bytes in the dataset's
/// byte order.
typedef RawElement = (int tag, String vr, List<int> value);

/// [elements] (in ascending tag order) encoded as Explicit VR in [endian],
/// then parsed in [transferSyntax], so `ds.transferSyntax` is set as it is
/// for a file. This is how the tests reach Big Endian, which core reads but
/// never writes.
Dataset parsed(List<RawElement> elements,
    {Endian endian = Endian.little, Uid? transferSyntax}) {
  final out = BytesBuilder();
  for (final (tag, vr, value) in elements) {
    final head = ByteData(12)
      ..setUint16(0, tag >> 16, endian)
      ..setUint16(2, tag & 0xFFFF, endian)
      ..setUint8(4, vr.codeUnitAt(0))
      ..setUint8(5, vr.codeUnitAt(1));
    if (const {'OB', 'OW', 'OF', 'OL', 'OD', 'SQ', 'UT', 'UN'}.contains(vr)) {
      head.setUint32(8, value.length, endian);
      out.add(head.buffer.asUint8List());
    } else {
      head.setUint16(6, value.length, endian);
      out.add(head.buffer.asUint8List(0, 8));
    }
    out.add(value);
  }
  return Dataset.fromBytes(out.takeBytes(),
      transferSyntax: transferSyntax ??
          (endian == Endian.little
              ? TransferSyntaxes.explicitVrLittleEndian
              : TransferSyntaxes.explicitVrBigEndian));
}

/// The Image Pixel module as [RawElement]s, ready for [parsed]; Pixel Data
/// goes after it.
List<RawElement> pixelModule(
        {required int rows,
        required int columns,
        required int bitsAllocated,
        int? bitsStored,
        int samples = 1,
        String photometric = 'MONOCHROME2',
        int? planar,
        int? frames,
        bool signed = false,
        Endian endian = Endian.little}) =>
    [
      (0x00280002, 'US', us(samples, endian)),
      (0x00280004, 'CS', text(photometric)),
      if (planar != null) (0x00280006, 'US', us(planar, endian)),
      if (frames != null) (0x00280008, 'IS', text('$frames')),
      (0x00280010, 'US', us(rows, endian)),
      (0x00280011, 'US', us(columns, endian)),
      (0x00280100, 'US', us(bitsAllocated, endian)),
      (0x00280101, 'US', us(bitsStored ?? bitsAllocated, endian)),
      (0x00280103, 'US', us(signed ? 1 : 0, endian)),
    ];

/// A US value.
List<int> us(int value, [Endian endian = Endian.little]) =>
    (ByteData(2)..setUint16(0, value, endian)).buffer.asUint8List();

/// A text value padded to even length.
List<int> text(String value) =>
    ascii.encode(value.length.isOdd ? '$value ' : value);

/// The Pixel Data tag, for [parsed].
const pixelDataTag = 0x7FE00010;
