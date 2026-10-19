import 'dart:typed_data';

import '../bytes.dart';
import '../items.dart';
import '../pdv.dart';

part 'associate.dart';
part 'data.dart';
part 'release_abort.dart';

/// A Protocol Data Unit of the DICOM Upper Layer (PS3.8 §9.3): one of
/// seven, each `type | reserved | length (4 bytes, big-endian) | body`.
sealed class Pdu {
  const Pdu();

  /// The PDU type byte.
  int get type;

  /// One line for the trace: the type and what it carries, never a value
  /// (I-9). AE titles and UIDs of SOP classes and syntaxes are protocol
  /// parameters, not patient data.
  String get summary;

  /// The whole PDU: the 6-byte header and the body.
  Uint8List encode() {
    final body = PduWriter();
    encodeBody(body);
    final out = PduWriter()
      ..u8(type)
      ..u8(0)
      ..u32(body.length)
      ..bytes(body.take());
    return out.take();
  }

  void encodeBody(PduWriter w);

  /// Decodes one whole PDU. Throws a [FormatException] if it is malformed
  /// or of an unknown type: the DUL's invalid-PDU event (Evt19).
  static Pdu decode(Uint8List pdu) {
    final r = PduReader(pdu);
    final type = r.u8();
    r.skip(1);
    final length = r.u32();
    if (6 + length != pdu.length) {
      throw const FormatException('PDU length disagrees with its size');
    }
    if ((type == 0x03 || type == 0x05 || type == 0x06 || type == 0x07) &&
        length != 4) {
      throw const FormatException(
          'fixed-body PDU must contain exactly 4 body bytes');
    }
    return switch (type) {
      0x01 => AssociateRq._decode(r),
      0x02 => AssociateAc._decode(r),
      0x03 => AssociateRj._decode(r),
      0x04 => PDataTf._decode(r),
      0x05 => const ReleaseRq(),
      0x06 => const ReleaseRp(),
      0x07 => Abort._decode(r),
      _ =>
        throw FormatException('unknown PDU type 0x${type.toRadixString(16)}'),
    };
  }
}
