import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../errors.dart';
import '../source/byte_source.dart';

/// A [ByteSource] over a file, read synchronously through a read-ahead
/// window: a header-only read of a large file touches only its first
/// windows (PRD C-20). Reads are owned copies (F19).
///
/// Close it when parsing is done; deferred values reopen the file through
/// [opener].
final class FileSource implements ByteSource {
  FileSource._(this._file, this.length, this.opener);

  /// Opens [file] for reading.
  factory FileSource.open(File file) {
    final stat = file.statSync();
    final raf = file.openSync();
    return FileSource._(raf, raf.lengthSync(),
        FileSourceOpener(file.absolute.path, stat.size, stat.modified));
  }

  /// The read-ahead window, in bytes.
  static const window = 64 * 1024;

  final RandomAccessFile _file;

  @override
  final int length;

  @override
  final FileSourceOpener opener;

  Uint8List _buffer = Uint8List(0);
  int _bufferStart = 0;

  /// How many bytes this source has read from the file so far.
  int get bytesRead => _bytesRead;
  int _bytesRead = 0;

  @override
  Uint8List read(int offset, int count) {
    if (count >= window) return Uint8List.fromList(_readAt(offset, count));
    final end = offset + count;
    if (offset < _bufferStart || end > _bufferStart + _buffer.length) {
      _buffer = _readAt(offset, math.min(window, length - offset));
      _bufferStart = offset;
    }
    final at = offset - _bufferStart;
    return Uint8List.fromList(Uint8List.sublistView(_buffer, at, at + count));
  }

  Uint8List _readAt(int offset, int count) {
    _file.setPositionSync(offset);
    final bytes = _file.readSync(count);
    _bytesRead += bytes.length;
    return bytes;
  }

  /// Closes the file.
  void close() => _file.closeSync();
}

/// Reads a file again for a deferred value, if it hasn't changed: same size
/// and modification time as when it was parsed, else a
/// [SourceChangedException] (DA2). Sendable to another isolate (I-14).
final class FileSourceOpener implements SourceOpener {
  const FileSourceOpener(this.path, this.size, this.modified);

  /// The absolute path of the file.
  final String path;

  /// Its size when it was parsed.
  final int size;

  /// Its modification time when it was parsed.
  final DateTime modified;

  @override
  Uint8List read(int offset, int count) {
    final file = File(path);
    final stat = file.statSync();
    if (stat.type == FileSystemEntityType.notFound ||
        stat.size != size ||
        stat.modified != modified) {
      throw SourceChangedException();
    }
    final raf = file.openSync();
    try {
      raf.setPositionSync(offset);
      return raf.readSync(count);
    } finally {
      raf.closeSync();
    }
  }
}
