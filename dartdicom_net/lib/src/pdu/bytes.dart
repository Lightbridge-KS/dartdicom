import 'dart:convert';
import 'dart:typed_data';

/// Big-endian writing for PDUs (PS3.8 §9.3: every PDU field is big-endian).
final class PduWriter {
  final _out = BytesBuilder(copy: false);

  int get length => _out.length;

  void u8(int v) => _out.addByte(v);

  void u16(int v) => _out.add([v >> 8 & 0xFF, v & 0xFF]);

  void u32(int v) =>
      _out.add([v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF]);

  void zeros(int n) => _out.add(Uint8List(n));

  void bytes(List<int> b) => _out.add(b);

  void ascii(String s) => _out.add(latin1.encode(s));

  /// An AE title: 16 bytes, space-padded.
  void aeTitle(String ae) {
    final b = latin1.encode(ae);
    _out
      ..add(b.length > 16 ? b.sublist(0, 16) : b)
      ..add(List.filled(16 - (b.length > 16 ? 16 : b.length), 0x20));
  }

  /// An item: type, a reserved byte, a 2-byte length, then [body].
  void item(int type, void Function(PduWriter w) body) {
    final w = PduWriter();
    body(w);
    u8(type);
    u8(0);
    u16(w.length);
    _out.add(w.take());
  }

  Uint8List take() => _out.takeBytes();
}

/// Big-endian reading for PDUs, bounds-checked: running past [end] throws a
/// [FormatException], which the DUL treats as an invalid PDU (Evt19).
final class PduReader {
  PduReader(this.bytes, [this.at = 0, int? end])
      : end = end ?? bytes.length,
        _data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _data;
  int at;
  final int end;

  bool get done => at >= end;

  void _need(int n) {
    if (at + n > end) {
      throw const FormatException('PDU field runs past its end');
    }
  }

  int u8() {
    _need(1);
    return _data.getUint8(at++);
  }

  int u16() {
    _need(2);
    final v = _data.getUint16(at);
    at += 2;
    return v;
  }

  int u32() {
    _need(4);
    final v = _data.getUint32(at);
    at += 4;
    return v;
  }

  void skip(int n) {
    _need(n);
    at += n;
  }

  Uint8List take(int n) {
    _need(n);
    final v = Uint8List.sublistView(bytes, at, at + n);
    at += n;
    return v;
  }

  /// Text with trailing NUL and space padding removed (and leading spaces
  /// too, which are never significant in AE titles or UIDs).
  String text(int n) =>
      latin1.decode(take(n)).replaceAll(RegExp(r'[\x00 ]+$'), '').trimLeft();

  /// Walks the items from [at] to [end], each `type | reserved | length (2)
  /// | body`: the reading side of [PduWriter.item]. [each] reads one body,
  /// which ends at `itemEnd`; whatever it leaves unread is skipped. An item
  /// that runs past [end], the end of the item or PDU holding it, is a
  /// [FormatException].
  void items(int end, void Function(int type, int itemEnd) each) {
    while (at < end) {
      final type = u8();
      skip(1);
      final length = u16();
      final itemEnd = at + length;
      if (itemEnd > end) {
        throw const FormatException(
            'an item runs past the item or PDU that holds it');
      }
      each(type, itemEnd);
      at = itemEnd;
    }
  }
}
