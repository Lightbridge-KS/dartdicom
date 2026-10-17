import '../vr.dart';

// The family each VR's value belongs to: raw bytes, text, or binary numbers.
// `value_codec.dart` dispatches on these and re-exports them.

/// Text VRs decoded with the Specific Character Set; the rest are ASCII.
const _charsetVrs = {Vr.SH, Vr.LO, Vr.ST, Vr.LT, Vr.UC, Vr.UT, Vr.PN};

/// Whether [vr] holds text (or text-encoded numbers: DS and IS).
bool isTextVr(Vr vr) => switch (vr) {
      Vr.AE ||
      Vr.AS ||
      Vr.CS ||
      Vr.DA ||
      Vr.DS ||
      Vr.DT ||
      Vr.IS ||
      Vr.LO ||
      Vr.LT ||
      Vr.PN ||
      Vr.SH ||
      Vr.ST ||
      Vr.TM ||
      Vr.UC ||
      Vr.UI ||
      Vr.UR ||
      Vr.UT =>
        true,
      _ => false,
    };

/// Whether [vr]'s text depends on the Specific Character Set.
bool isCharsetVr(Vr vr) => _charsetVrs.contains(vr);

/// Whether [vr] is one of the "other" binary VRs, held as raw bytes.
bool isBytesVr(Vr vr) => switch (vr) {
      Vr.OB || Vr.OD || Vr.OF || Vr.OL || Vr.OV || Vr.OW || Vr.UN => true,
      _ => false,
    };

/// The Dart type of one value of a VR (data architecture §3.4): the family
/// the untyped getters and `setRaw` dispatch on.
enum ValueFamily { string, int, double, bigInt, tag, bytes, sequence }

/// The family of [vr]'s values.
ValueFamily familyOf(Vr vr) => switch (vr) {
      Vr.SQ => ValueFamily.sequence,
      Vr.AT => ValueFamily.tag,
      Vr.SV || Vr.UV => ValueFamily.bigInt,
      Vr.DS || Vr.FL || Vr.FD => ValueFamily.double,
      Vr.IS || Vr.US || Vr.SS || Vr.UL || Vr.SL => ValueFamily.int,
      _ when isBytesVr(vr) => ValueFamily.bytes,
      _ => ValueFamily.string,
    };
