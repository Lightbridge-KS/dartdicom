import 'dart:io';

import 'package:dartdicom/dartdicom.dart';

import 'instance_sink.dart';

/// Stores each received instance as a Part 10 file under [root]:
/// `<StudyInstanceUID>/<SeriesInstanceUID>/<SOPInstanceUID>.dcm`.
///
/// - **Store as received:** the file is the generated file meta, then the
///   dataset bytes exactly as they came (data §4.2, I-20). Only the header
///   is parsed, for the two UIDs in the path (F39).
/// - **UIDs only in paths:** no patient attribute ever names a file, and a
///   UID that isn't digits and dots is refused (I-21).
/// - **Whole or absent:** each file is written as `.dcm.part`, then
///   renamed (F25).
final class DirectorySink implements InstanceSink {
  DirectorySink(this.root);

  /// The directory files are stored under; created as needed.
  final Directory root;

  /// The file each stored instance went to, in order.
  final stored = <File>[];

  @override
  Future<void> accept(ReceivedInstance instance) async {
    final header =
        instance.parse(options: const ReadOptions(stopBeforePixels: true));
    final parts = [
      _uid(header.get(DicomTags.studyInstanceUid), 'StudyInstanceUID'),
      _uid(header.get(DicomTags.seriesInstanceUid), 'SeriesInstanceUID'),
      _uid(instance.sopInstanceUid.value, 'SOPInstanceUID'),
    ];
    final dir = Directory.fromUri(root.uri.resolve('${parts[0]}/${parts[1]}/'));
    await dir.create(recursive: true);
    final target = File.fromUri(dir.uri.resolve('${parts[2]}.dcm'));
    final partial = File('${target.path}.part');
    final out = await partial.open(mode: FileMode.writeOnly);
    try {
      await out.writeFrom(instance.fileMeta.toHeaderBytes());
      await out.writeFrom(instance.bytes);
      await out.flush();
    } finally {
      await out.close();
    }
    stored.add(await partial.rename(target.path));
  }

  static String _uid(String? uid, String keyword) {
    if (uid == null ||
        !RegExp(r'^[0-9][0-9.]*$').hasMatch(uid) ||
        uid.length > 64) {
      throw FormatException(
          'the instance has no valid $keyword to name its file by');
    }
    return uid;
  }
}
