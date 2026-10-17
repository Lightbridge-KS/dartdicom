// I-24: typed-tag misuse that must not compile. The package's analysis
// excludes this folder; test/gates/compile_fail_test.dart analyzes each file
// here on its own and expects exactly the diagnostics marked.
//
// `// expect: <code>` says the next line must fail with that diagnostic.
// `// gap: <why>` says the next line still compiles: Dart widens T to Object
// when the tag and the value disagree, so Dataset.set and setAll check the
// type at runtime instead. Once a gap line fails to compile, the check fails
// too, so closing the gap is a deliberate edit to this file.
import 'package:dartdicom/dartdicom.dart';

void misuse(Dataset ds) {
  // A Many tag read as one value, and a One tag read as several.
  // expect: argument_type_not_assignable
  ds.get(DicomTags.imageType);
  // expect: argument_type_not_assignable
  ds.getAll(DicomTags.rows);

  // A Many tag written as one value, and a One tag written as several.
  // expect: argument_type_not_assignable
  ds.set(DicomTags.imageType, 'ORIGINAL');
  // expect: argument_type_not_assignable
  ds.setAll(DicomTags.rows, [512]);

  // The wrong value type.
  // gap: T widens to Object
  ds.set(DicomTags.rows, 'not a number');
  // gap: T widens to Object
  ds.setAll(DicomTags.windowCenter, ['not', 'numbers']);
}
