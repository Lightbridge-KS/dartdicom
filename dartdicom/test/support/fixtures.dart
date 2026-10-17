// The test data on disk: the committed fixtures (fixtures/data/), found from
// the package root, where `dart test` runs, and pydicom's golden records.
// VM only: it reads files.
import 'dart:convert';
import 'dart:io';

import 'package:dartdicom/dartdicom.dart';

const _root = '../fixtures/data';

/// The fixture at [path], relative to fixtures/data/ (e.g.
/// `synthetic/ct_implicit_le.dcm`).
File fixture(String path) => File('$_root/$path');

/// The fixture directory at [path], relative to fixtures/data/.
Directory fixtureDirectory(String path) => Directory('$_root/$path');

/// The fixture at [path], read with [options].
DicomFile readFixture(String path,
        {ReadOptions options = const ReadOptions()}) =>
    DicomFile.fromBytes(fixture(path).readAsBytesSync(), options: options);

/// The fixture set: every `.dcm` file of the synthetic and pydicom sets,
/// sorted by path; with [under], only those smaller than [under] bytes.
///
/// The order is fixed, so a test that picks fixtures by index (the seeded
/// fuzzer) reproduces.
List<File> fixtureSet({int? under}) => [
      for (final dir in ['synthetic', 'pydicom'])
        ...fixtureDirectory(dir).listSync().whereType<File>().where((f) =>
            f.path.endsWith('.dcm') &&
            (under == null || f.lengthSync() < under)),
    ]..sort((a, b) => a.path.compareTo(b.path));

/// [file]'s name in the fixture set: its set and its file name, e.g.
/// `synthetic/ct_implicit_le.dcm`.
String fixtureName(File file) =>
    file.uri.pathSegments.skip(file.uri.pathSegments.length - 2).join('/');

/// The golden records under [root]: pydicom's reading of each file, one JSON
/// record per file, sorted by the record's path.
List<Map<String, Object?>> goldenRecords(Directory root) => [
      for (final golden
          in root
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
        jsonDecode(golden.readAsStringSync()) as Map<String, Object?>,
    ];
