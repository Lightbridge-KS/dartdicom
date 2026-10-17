/// Native file access for dartdicom: read and write DICOM files by path
/// (PRD C-20). Needs `dart:io`, so it is not available on the web; use
/// `DicomFile.fromBytes` there.
library;

import 'dart:io';

import 'src/file/dicom_file.dart';
import 'src/read/read_options.dart';

/// DICOM reads and writes on a [File], mirroring `readAsBytes` and
/// `writeAsBytes`.
///
/// ```dart
/// final file = await File('ct.dcm').readAsDicom();
/// await File('copy.dcm').writeAsDicom(file);
/// ```
extension DicomFileIO on File {
  /// Reads and parses this file.
  Future<DicomFile> readAsDicom(
          {ReadOptions options = const ReadOptions()}) async =>
      DicomFile.fromBytes(await readAsBytes(), options: options);

  /// Reads and parses this file synchronously.
  DicomFile readAsDicomSync({ReadOptions options = const ReadOptions()}) =>
      DicomFile.fromBytes(readAsBytesSync(), options: options);

  /// Encodes [file] and writes it here, replacing any existing file.
  Future<File> writeAsDicom(DicomFile file) =>
      writeAsBytes(file.toBytes(), flush: true);

  /// Encodes [file] and writes it here synchronously.
  void writeAsDicomSync(DicomFile file) =>
      writeAsBytesSync(file.toBytes(), flush: true);
}
