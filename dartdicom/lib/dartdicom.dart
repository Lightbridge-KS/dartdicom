/// Read, modify and write DICOM data in pure Dart.
///
/// This library imports no `dart:io`, `dart:ffi` or Flutter, so it runs on
/// every Dart platform. Native file access is in `package:dartdicom/io.dart`.
library;

export 'src/dataset/dataset.dart' show Dataset;
export 'src/dataset/element.dart' show DataElement;
export 'src/dataset/sequence.dart';
export 'src/dictionary/dictionary.dart' show Dictionary;
export 'src/dictionary/dictionary_entry.dart' show DictionaryEntry;
export 'src/errors.dart';
export 'src/tag/tag.dart';
export 'src/tag/tags.g.dart';
export 'src/tag/typed_tag.dart';
export 'src/uid/implementation.dart';
export 'src/uid/transfer_syntax.dart';
export 'src/uid/uid.dart';
export 'src/uid/uids.g.dart';
export 'src/vr/vr.dart';
