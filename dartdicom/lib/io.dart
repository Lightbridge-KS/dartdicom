/// Native file access for dartdicom: read and write DICOM files by path
/// (PRD C-20). Needs `dart:io`, so it is not available on the web; use
/// `DicomFile.fromBytes` there.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'src/file/dicom_file.dart';
import 'src/io/file_source.dart';
import 'src/read/read_options.dart';
import 'src/source/byte_source.dart';

export 'src/io/file_source.dart';

/// DICOM reads and writes on a [File], mirroring `readAsBytes` and
/// `writeAsBytes`.
///
/// ```dart
/// final file = await File('ct.dcm').readAsDicom();
/// await File('copy.dcm').writeAsDicom(file);
/// ```
///
/// A header-only read (`stopBeforePixels`) or a deferred one (`deferSize`)
/// reads only what it needs, however large the file.
extension DicomFileIO on File {
  /// Reads and parses this file.
  ///
  /// A full read loads the file at once. A header-only or deferred read
  /// fetches a prefix and grows it until the parser has what it needs
  /// (design D1), so the skipped values are never read.
  Future<DicomFile> readAsDicom(
      {ReadOptions options = const ReadOptions()}) async {
    if (!options.stopBeforePixels && options.deferSize == null) {
      return DicomFile.fromBytes(await readAsBytes(), options: options);
    }
    final stat = await this.stat();
    final opener = FileSourceOpener(absolute.path, stat.size, stat.modified);
    final raf = await open();
    try {
      final length = await raf.length();
      var prefix = await raf.read(math.min(length, FileSource.window));
      while (true) {
        try {
          return DicomFile.fromSource(
              PrefixSource(prefix, length, opener: opener),
              options: options);
        } on NeedMoreBytes catch (need) {
          // Grow geometrically, so re-parsing costs at most about twice one
          // parse of the final prefix.
          final target =
              math.min(length, math.max(need.end, prefix.length * 2));
          final more = await raf.read(target - prefix.length);
          prefix = (BytesBuilder(copy: false)
                ..add(prefix)
                ..add(more))
              .takeBytes();
        }
      }
    } finally {
      await raf.close();
    }
  }

  /// Reads and parses this file synchronously, through a [FileSource].
  DicomFile readAsDicomSync({ReadOptions options = const ReadOptions()}) {
    final source = FileSource.open(this);
    try {
      return DicomFile.fromSource(source, options: options);
    } finally {
      source.close();
    }
  }

  /// Encodes [file] and writes it here, replacing any existing file.
  Future<File> writeAsDicom(DicomFile file) =>
      writeAsBytes(file.toBytes(), flush: true);

  /// Encodes [file] and writes it here synchronously.
  void writeAsDicomSync(DicomFile file) =>
      writeAsBytesSync(file.toBytes(), flush: true);
}
