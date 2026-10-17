import 'dart:async';
import 'dart:typed_data';

/// The largest PDU accepted from a peer, whatever it negotiated: a hard cap
/// so a corrupt length field can't exhaust memory.
const maxPduBytes = 64 * 1024 * 1024;

/// Splits a TCP byte stream into whole PDUs (`type | reserved | length (4) |
/// body`), whatever the chunking. A length above the cap is an error: by
/// default [maxPduBytes], or what [maxLength] says when each PDU starts
/// (an acceptor caps PDUs tighter until it accepts an association).
///
/// Bytes accumulate in one growing buffer, so framing costs linear time in
/// the bytes received, not quadratic in the number of chunks.
final class PduFramer extends StreamTransformerBase<Uint8List, Uint8List> {
  const PduFramer({this.maxLength});

  /// The cap for the next PDU; `null` means [maxPduBytes].
  final int Function()? maxLength;

  @override
  Stream<Uint8List> bind(Stream<Uint8List> stream) {
    var buffer = Uint8List(64 * 1024);
    var length = 0;
    late StreamController<Uint8List> out;
    StreamSubscription<Uint8List>? sub;

    void onData(Uint8List chunk) {
      if (length + chunk.length > buffer.length) {
        var size = buffer.length;
        while (size < length + chunk.length) {
          size *= 2;
        }
        buffer = Uint8List(size)..setRange(0, length, buffer);
      }
      buffer.setRange(length, length + chunk.length, chunk);
      length += chunk.length;
      var start = 0;
      while (length - start >= 6) {
        final body =
            ByteData.sublistView(buffer, start + 2, start + 6).getUint32(0);
        final cap = maxLength?.call() ?? maxPduBytes;
        if (body > cap) {
          out.addError(FormatException(
              'a PDU declares $body bytes, more than the $cap allowed'));
          sub?.cancel();
          out.close();
          return;
        }
        final end = start + 6 + body;
        if (end > length) break;
        out.add(Uint8List.fromList(Uint8List.sublistView(buffer, start, end)));
        start = end;
      }
      if (start > 0) {
        buffer.setRange(0, length - start, buffer, start);
        length -= start;
      }
    }

    out = StreamController<Uint8List>(
      onListen: () {
        sub = stream.listen(onData, onError: out.addError, onDone: () {
          if (length > 0) {
            out.addError(const FormatException(
                'the connection closed in the middle of a PDU'));
          }
          out.close();
        });
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }
}
