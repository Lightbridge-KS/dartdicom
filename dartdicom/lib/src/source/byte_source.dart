import 'dart:typed_data';

// Where the parser's bytes come from (design D1, blueprint §5, F40). A leaf:
// it imports nothing else from the package, so both dataset/ (which holds
// deferred values) and read/ (which parses) can depend on it.

/// Random access to the bytes being parsed: memory, a file, or a prefix of
/// something larger (a browser `Blob`, a file read asynchronously).
///
/// The parser is synchronous (design D1). A source that doesn't hold a range
/// yet throws [NeedMoreBytes]; an async driver fetches it and parses again.
abstract interface class ByteSource {
  /// The total length in bytes, including any not fetched yet.
  int get length;

  /// [count] bytes from [offset]. The parser checks the range against
  /// [length] first. [BytesSource] returns views; sources that read from
  /// elsewhere return copies they don't keep (F19).
  Uint8List read(int offset, int count);

  /// How to read this source's bytes again later, for deferred values; or
  /// `null` when values can't be deferred (the bytes are already in memory).
  SourceOpener? get opener;
}

/// Reads bytes again, after the source they were parsed from is gone: how
/// a deferred value loads on first access (C-09, design §7).
///
/// An opener must be **sendable** to another isolate, so a lazily read
/// dataset can move to a worker (I-14). Hold a path and metadata, never an
/// open handle.
abstract interface class SourceOpener {
  /// [count] bytes from [offset]. Throws `SourceChangedException` if the
  /// bytes may no longer be the ones that were parsed (DA2).
  Uint8List read(int offset, int count);
}

/// The range a [ByteSource] needs but doesn't hold yet: everything up to
/// [end] (exclusive). A control signal for async drivers, not an error.
final class NeedMoreBytes implements Exception {
  const NeedMoreBytes(this.end);

  /// The offset the source must reach.
  final int end;

  @override
  String toString() => 'NeedMoreBytes($end)';
}

/// A [ByteSource] over bytes in memory. Reads are zero-copy views, so a
/// value parsed from it pins [bytes] for as long as the value lives
/// (data §6).
final class BytesSource implements ByteSource {
  BytesSource(this.bytes);

  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  Uint8List read(int offset, int count) =>
      Uint8List.sublistView(bytes, offset, offset + count);

  @override
  SourceOpener? get opener => null;
}

/// A [ByteSource] holding only the first [prefix] bytes of a source of
/// [length] bytes: reading past the prefix throws [NeedMoreBytes]. Reads
/// are copies, so the prefix isn't pinned once parsing is done.
final class PrefixSource implements ByteSource {
  PrefixSource(this.prefix, this.length, {this.opener});

  final Uint8List prefix;

  @override
  final int length;

  @override
  final SourceOpener? opener;

  @override
  Uint8List read(int offset, int count) {
    if (offset + count > prefix.length) throw NeedMoreBytes(offset + count);
    return Uint8List.fromList(
        Uint8List.sublistView(prefix, offset, offset + count));
  }
}
