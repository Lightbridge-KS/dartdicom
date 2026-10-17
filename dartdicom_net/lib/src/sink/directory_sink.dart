import 'dart:io';
import 'dart:math';

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
/// - **Whole or absent:** each file is written under a name of its own
///   ending `.part`, then renamed (F25). Two associations storing the same
///   instance at once can't write into one file.
final class DirectorySink implements InstanceSink {
  DirectorySink(this.root);

  /// The directory files are stored under; created as needed.
  final Directory root;

  /// The file each stored instance went to, in order. It grows with every
  /// instance: a long-running `StorageScp` keeps a sink per session.
  final stored = <File>[];

  final _random = Random();
  var _count = 0;

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
    final partial = File('${target.path}.'
        '${_random.nextInt(0x7FFFFFFF).toRadixString(36)}-${_count++}.part');
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
