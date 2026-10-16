/// DICOM keyword → Dart identifier (surface S4): lowerCamelCase, with
/// acronyms folded like words, e.g. `SOPInstanceUID` → `sopInstanceUid`.
library;

/// Splits a keyword into words: acronym runs (`SOP`), capitalized words
/// (`Instance`), lowercase runs and digit runs (`3`).
final _word = RegExp(r'[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|[0-9]+');

/// Dart's reserved words, which can't be used as identifiers.
const _reserved = {
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', //
  'default', 'do', 'else', 'enum', 'extends', 'false', 'final', 'finally',
  'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return', 'super',
  'switch', 'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with',
};

/// The Dart identifier for DICOM [keyword].
///
/// Throws [ArgumentError] when the keyword yields no words or a reserved
/// word, so a new release can't silently produce an unusable name.
String identifierFor(String keyword) {
  final words = _word.allMatches(keyword).map((m) => m[0]!).toList();
  if (words.isEmpty || words.join() != keyword) {
    throw ArgumentError.value(keyword, 'keyword', 'cannot be split into words');
  }
  final buffer = StringBuffer(words.first.toLowerCase());
  for (final word in words.skip(1)) {
    buffer
      ..write(word[0].toUpperCase())
      ..write(word.substring(1).toLowerCase());
  }
  final identifier = buffer.toString();
  if (_reserved.contains(identifier)) {
    throw ArgumentError.value(keyword, 'keyword', 'maps to reserved word');
  }
  return identifier;
}
