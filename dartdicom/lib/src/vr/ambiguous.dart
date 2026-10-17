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
