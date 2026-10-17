import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';
import '../tag/tag.dart';

/// Text decoding and encoding by Specific Character Set (0008,0005),
/// PRD C-12: the default repertoire, `ISO_IR 100` (Latin-1) and `ISO_IR 192`
/// (UTF-8). Only the first value is used: ISO 2022 code extensions are C-14.
///
/// Reading is lenient: the default repertoire and any term this version
/// doesn't know decode as Latin-1, as pydicom does. Writing is strict
/// (data §3.4, F35).
enum _Charset { ascii, latin1, utf8, unsupported }

_Charset _charsetOf(List<String> specificCharacterSet) {
  final term =
      specificCharacterSet.isEmpty ? '' : specificCharacterSet.first.trim();
  return switch (term) {
    '' || 'ISO_IR 6' || 'ISO 2022 IR 6' => _Charset.ascii,
    'ISO_IR 100' || 'ISO 2022 IR 100' => _Charset.latin1,
    'ISO_IR 192' => _Charset.utf8,
    _ => _Charset.unsupported,
  };
}

/// Decodes the bytes of a text value (SH, LO, ST, LT, UC, UT, PN) under
/// [specificCharacterSet].
String decodeText(Uint8List bytes, List<String> specificCharacterSet) =>
    switch (_charsetOf(specificCharacterSet)) {
      _Charset.utf8 => utf8.decode(bytes, allowMalformed: true),
      _ => latin1.decode(bytes),
    };

/// Encodes [text] for element [tag] under [specificCharacterSet].
///
/// Throws a [DicomWriteException] naming the tag and the fix when the
/// declared character set can't encode the text, or when non-ASCII text
/// has no Specific Character Set at all (F35). Never adds or changes
/// (0008,0005) on its own.
Uint8List encodeText(String text, List<String> specificCharacterSet, Tag tag) {
  switch (_charsetOf(specificCharacterSet)) {
    case _Charset.utf8:
      return utf8.encode(text);
    case _Charset.latin1:
      if (text.codeUnits.any((c) => c > 0xFF)) {
        throw DicomWriteException(
            'the text has characters that ISO_IR 100 (Latin-1) cannot '
            "encode; set DicomTags.specificCharacterSet to 'ISO_IR 192'",
            tag: tag);
      }
      return latin1.encode(text);
    case _Charset.ascii:
      if (text.codeUnits.any((c) => c > 0x7F)) {
        throw DicomWriteException(
            'the text is not ASCII and the dataset declares no Specific '
            "Character Set; set DicomTags.specificCharacterSet to 'ISO_IR 192'",
            tag: tag);
      }
      return ascii.encode(text);
    case _Charset.unsupported:
      throw DicomWriteException(
          'the declared Specific Character Set is not supported for writing '
          'yet (supported: ISO_IR 6, ISO_IR 100, ISO_IR 192)',
          tag: tag);
  }
}
