import 'vr.dart';

/// Picks one VR for a dictionary entry that allows several (`US or SS`,
/// `OB or OW`, …), from the pixel module context (PS3.5 §A.1 c, PRD C-10).
///
/// A first approximation of pydicom's rules: words when pixels are wider
/// than a byte, signed when Pixel Representation says so. The rest of
/// C-10's lenient reading refines it.
Vr resolveVr(List<Vr> vrs, {int? bitsAllocated, int? pixelRepresentation}) {
  if (vrs.length == 1) return vrs.single;
  if (vrs.contains(Vr.OW) && vrs.contains(Vr.OB)) {
    return (bitsAllocated ?? 16) > 8 ? Vr.OW : Vr.OB;
  }
  if (vrs.contains(Vr.OW)) return Vr.OW;
  if (vrs.contains(Vr.SS) && vrs.contains(Vr.US)) {
    return pixelRepresentation == 1 ? Vr.SS : Vr.US;
  }
  return vrs.first;
}

// pydicom 3.0.2's ambiguous-VR rules for data as read (filewriter.py
// _correct_ambiguous_vr_element), applied to elements whose VR came from the
// dictionary: Implicit VR data, and UN given its dictionary VR (PRD C-10).

/// The tags whose `US or SS` follows Pixel Representation.
const _usOrSsTags = {
  0x00189810, 0x00221452, 0x00280104, 0x00280105, 0x00280106, //
  0x00280107, 0x00280108, 0x00280109, 0x00280110, 0x00280111,
  0x00280120, 0x00280121, 0x00281101, 0x00281102, 0x00281103,
  0x00283002, 0x00409211, 0x00409216, 0x00603004, 0x00603006,
};

/// The waveform tags whose `OB or OW` follows Waveform Bits Allocated.
const _waveformTags = {0x54000110, 0x54000112, 0x5400100A, 0x54001010};

const _pixelData = 0x7FE00010;
const _lutData = 0x00283006;

/// The tags whose first value pydicom raises by 65536 when it reads as
/// negative (an SS LUT Descriptor, PS3.3 C.11.1.1.1).
const lutDescriptorTags = {0x00281101, 0x00281102, 0x00281103, 0x00283002};

/// What [resolveReadVr] needs to know about the dataset an element is in
/// (and, for Pixel Representation, the datasets around it).
typedef AmbiguityFacts = ({
  bool implicit,
  bool undefinedLength,
  int? bitsAllocated,
  int? pixelRepresentation,
  bool hasPixelData,
  int? waveformBitsAllocated,
  int? lutDescriptorFirst,
});

/// The VR pydicom gives element [tag], read with an ambiguous dictionary
/// entry [vrs], from [facts]; `null` where pydicom leaves it ambiguous (a
/// literal `"US or SS"`), and the first VR stands.
Vr? resolveReadVr(int tag, List<Vr> vrs, AmbiguityFacts facts) {
  if (vrs.length == 1) return vrs.single;
  if (tag == _pixelData) {
    if (facts.undefinedLength) return Vr.OB;
    if (facts.implicit) return Vr.OW;
    return (facts.bitsAllocated ?? 16) > 8 ? Vr.OW : Vr.OB;
  }
  if (_usOrSsTags.contains(tag)) {
    final pr = facts.pixelRepresentation ?? (facts.hasPixelData ? 1 : 0);
    return pr == 0 ? Vr.US : Vr.SS;
  }
  if (_waveformTags.contains(tag)) {
    if (facts.implicit) return Vr.OW;
    return (facts.waveformBitsAllocated ?? 16) > 8 ? Vr.OW : Vr.OB;
  }
  if (tag == _lutData) return facts.lutDescriptorFirst == 1 ? Vr.US : Vr.OW;
  // (60xx,3000) Overlay Data, xx even.
  if (tag & 0xFF01FFFF == 0x60003000) return Vr.OW;
  return null;
}
