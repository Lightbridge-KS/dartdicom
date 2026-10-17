import 'dart:convert';
import 'dart:typed_data';

import '../../charset/charset.dart';
import '../../errors.dart';
import '../../tag/tag.dart';
import '../vr.dart';
import 'vr_family.dart';

// The text family, DS and IS included. Stripping follows pydicom's, so
// values agree with it element for element (I-11).

/// Text VRs whose values are never split on backslash.
const _singleTextVrs = {Vr.LT, Vr.ST, Vr.UT, Vr.UR};

/// Decodes the text value [bytes]: a `List<String>`, or a `List<double>` /
/// `List<int>` for DS / IS.
List<Object> decodeTextValues(
    Tag tag, Vr vr, Uint8List bytes, List<String> specificCharacterSet) {
  final parts = _splitText(vr, bytes, specificCharacterSet);
  return switch (vr) {
    Vr.DS => List<double>.unmodifiable(parts.map((p) => _parseDs(tag, p))),
    Vr.IS => List<int>.unmodifiable(parts.map((p) => _parseIs(tag, p))),
    _ => parts,
  };
}

/// Encodes text [values], joined on backslash. Not padded: the caller pads.
Uint8List encodeTextValues(
    Tag tag, Vr vr, List<Object> values, List<String> specificCharacterSet) {
  final text = switch (vr) {
    Vr.DS => values.map((v) => _formatDs(tag, v as double)).join(r'\'),
    Vr.IS => values.map((v) => _formatIs(tag, v as int)).join(r'\'),
    _ => values.cast<String>().join(r'\'),
  };
  return isCharsetVr(vr)
      ? encodeText(text, specificCharacterSet, tag)
      : _encodeAscii(text, tag);
}

List<String> _splitText(
    Vr vr, Uint8List bytes, List<String> specificCharacterSet) {
  final raw = isCharsetVr(vr)
      ? decodeText(
          vr == Vr.PN ? _rstripBytes(bytes) : bytes, specificCharacterSet)
      : latin1.decode(bytes);
  if (_singleTextVrs.contains(vr)) {
    final s = vr == Vr.UR ? raw.trimRight() : _rstrip(raw);
    return s.isEmpty ? const [] : List.unmodifiable([s]);
  }
  final List<String> parts;
  switch (vr) {
    case Vr.AE:
      parts = [for (final p in raw.split(r'\')) p.trim()];
    case Vr.LO || Vr.SH || Vr.UC:
      parts = [for (final p in raw.split(r'\')) _rstrip(p)];
    default:
      parts = _rstrip(raw).split(r'\');
  }
  if (parts.length == 1 && parts.single.isEmpty) return const [];
  return List<String>.unmodifiable(parts);
}

double _parseDs(Tag tag, String text) {
  final value = double.tryParse(text.trim());
  if (value == null) {
    throw DicomParseException('a DS value component is empty or not a number',
        tag: tag);
  }
  return value;
}

int _parseIs(Tag tag, String text) {
  final trimmed = text.trim();
  final value = int.tryParse(trimmed) ??
      switch (double.tryParse(trimmed)) {
        final d? when d == d.truncateToDouble() => d.toInt(),
        _ => null,
      };
  if (value == null) {
    throw DicomParseException(
        'an IS value component is empty or not an integer',
        tag: tag);
  }
  return value;
}

String _formatDs(Tag tag, double value) {
  if (!value.isFinite) {
    throw DicomWriteException('a DS value must be finite', tag: tag);
  }
  var text = value.toString();
  for (var digits = 15; text.length > 16 && digits > 0; digits--) {
    text = value.toStringAsPrecision(digits);
  }
  if (text.length > 16) {
    throw DicomWriteException('a DS value cannot be written in 16 characters',
        tag: tag);
  }
  return text;
}

String _formatIs(Tag tag, int value) {
  if (value < -2147483648 || value > 2147483647) {
    throw DicomWriteException('an IS value must fit in 32 bits', tag: tag);
  }
  return value.toString();
}

Uint8List _encodeAscii(String text, Tag tag) {
  if (text.codeUnits.any((c) => c > 0x7F)) {
    throw DicomWriteException('this VR allows ASCII characters only', tag: tag);
  }
  return ascii.encode(text);
}

String _rstrip(String s) {
  var end = s.length;
  while (end > 0 &&
      (s.codeUnitAt(end - 1) == 0x20 || s.codeUnitAt(end - 1) == 0)) {
    end--;
  }
  return s.substring(0, end);
}

Uint8List _rstripBytes(Uint8List b) {
  var end = b.length;
  while (end > 0 && (b[end - 1] == 0x20 || b[end - 1] == 0)) {
    end--;
  }
  return Uint8List.sublistView(b, 0, end);
}
