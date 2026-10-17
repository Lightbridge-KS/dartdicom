import '../../dataset/element.dart';
import '../../vr/ambiguous.dart';
import '../../vr/vr.dart';
import 'header.dart';
import 'level.dart';

// Ambiguous VRs: noted while the walk runs, settled once it is done.

const _pixelData = 0x7FE00010;
const _bitsAllocated = 0x00280100;
const _pixelRepresentation = 0x00280103;
const _waveformBitsAllocated = 0x54001004;
const _lutDescriptor = 0x00283002;

/// An element whose VR came from an ambiguous dictionary entry, settled once
/// its level is complete.
typedef _Ambiguous = ({
  DataElement element,
  List<Vr> vrs,
  Level level,
  bool implicit,
  bool undefinedLength,
});

/// The elements whose VR is still to settle (pydicom's rules:
/// `resolveReadVr`), because the attributes that decide it can come later
/// in the level, or in a level around it.
final class AmbiguousVrs {
  final _pending = <_Ambiguous>[];

  /// Notes [element] if its [header] left its VR ambiguous.
  void note(DataElement element, ElementHeader header, Level level) {
    if (header.ambiguous case final vrs?) {
      _pending.add((
        element: element,
        vrs: vrs,
        level: level,
        implicit: !level.explicit,
        undefinedLength: header.undefinedLength,
      ));
    }
  }

  /// Settles each noted VR, now that every level is complete.
  void settle() {
    int? firstInt(List<DataElement> elements, int tag) {
      final value =
          elements.where((e) => e.tag.value == tag).firstOrNull?.value;
      return value is List<int> && value.isNotEmpty ? value.first : null;
    }

    for (final a in _pending) {
      int? pixelRepresentation;
      for (Level? l = a.level; l != null; l = l.parent) {
        pixelRepresentation = firstInt(l.elements, _pixelRepresentation);
        if (pixelRepresentation != null) break;
      }
      final vr = resolveReadVr(a.element.tag.value, a.vrs, (
        implicit: a.implicit,
        undefinedLength: a.undefinedLength,
        bitsAllocated: firstInt(a.level.elements, _bitsAllocated),
        pixelRepresentation: pixelRepresentation,
        hasPixelData: a.level.elements.any((e) => e.tag.value == _pixelData),
        waveformBitsAllocated:
            firstInt(a.level.elements, _waveformBitsAllocated),
        lutDescriptorFirst: firstInt(a.level.elements, _lutDescriptor),
      ));
      if (vr != null && vr != a.element.vr) retypeElement(a.element, vr);
    }
  }
}
