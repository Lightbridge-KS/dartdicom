/// The VR → Dart type contract (data architecture §3.4). Typed tags carry
/// these types, so changing a row is a breaking change (I-19).
library;

import 'package:dartdicom/src/vr/vr.dart';

/// The Dart type of one value of [vr].
String dartTypeOf(Vr vr) => switch (vr) {
      Vr.AE ||
      Vr.AS ||
      Vr.CS ||
      Vr.DA ||
      Vr.DT ||
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
        'String',
      Vr.DS || Vr.FD || Vr.FL => 'double',
      Vr.IS || Vr.SL || Vr.SS || Vr.UL || Vr.US => 'int',
      Vr.SV || Vr.UV => 'BigInt',
      Vr.OB ||
      Vr.OD ||
      Vr.OF ||
      Vr.OL ||
      Vr.OV ||
      Vr.OW ||
      Vr.UN =>
        'Uint8List',
      Vr.AT => 'Tag',
      Vr.SQ => 'Sequence',
    };

/// The Dart type for an entry allowing [vrs], or `null` when the
/// alternatives disagree (e.g. `US or OW`): such tags stay untyped.
String? dartTypeFor(List<Vr> vrs) {
  final types = {for (final vr in vrs) dartTypeOf(vr)};
  return types.length == 1 ? types.single : null;
}
