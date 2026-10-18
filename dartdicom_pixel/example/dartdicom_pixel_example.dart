import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_pixel/dartdicom_pixel.dart';

// A 4-pixel CT row in memory: Modality LUT → VOI window → 8-bit gray. It
// runs on every platform; CI also compiles it to Wasm.
void main() {
  final hu = Int16List.fromList([-1000, 0, 40, 1000]);
  final ds = Dataset()
    ..set(DicomTags.samplesPerPixel, 1)
    ..set(DicomTags.rows, 1)
    ..set(DicomTags.columns, hu.length)
    ..set(DicomTags.bitsAllocated, 16)
    ..set(DicomTags.bitsStored, 16)
    ..set(DicomTags.pixelRepresentation, 1)
    ..set(DicomTags.photometricInterpretation, 'MONOCHROME2')
    ..setAll(DicomTags.windowCenter, [40.0])
    ..setAll(DicomTags.windowWidth, [400.0])
    ..set(DicomTags.pixelData, hu.buffer.asUint8List());

  final buf = ds.pixels.frame(0).toDisplay(ds.voiWindow());
  print('$buf: ${buf.gray}');
}
