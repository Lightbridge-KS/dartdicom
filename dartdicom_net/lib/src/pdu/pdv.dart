import 'dart:typed_data';

import 'bytes.dart';

/// One Presentation Data Value: a fragment of a command or a dataset.
final class Pdv {
  const Pdv(this.contextId, this.data,
      {required this.isCommand, required this.isLast});

  final int contextId;
  final Uint8List data;

  /// Bit 0 of the control header: a command (1) or a dataset (0) fragment.
  final bool isCommand;

  /// Bit 1 of the control header: the last fragment of its message part.
  final bool isLast;

  /// Writes one PDV item: length, context ID, control header, and payload.
  void encode(PduWriter w) => w
    ..u32(data.length + 2)
    ..u8(contextId)
    ..u8((isCommand ? 1 : 0) | (isLast ? 2 : 0))
    ..bytes(data);

  /// Reads one PDV item, retaining a view of its payload in the input buffer.
  static Pdv decode(PduReader r) {
    final length = r.u32();
    if (length < 2) {
      throw const FormatException('a PDV is shorter than 2 bytes');
    }
    final contextId = r.u8();
    final header = r.u8();
    return Pdv(contextId, r.take(length - 2),
        isCommand: header & 1 != 0, isLast: header & 2 != 0);
  }
}
