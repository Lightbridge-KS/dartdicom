import 'dart:math' as math;

import '../../dataset/dataset.dart';
import '../../dataset/element.dart';
import '../../dataset/read_report.dart';
import '../../dataset/sequence.dart';
import '../../errors.dart';
import '../../source/byte_source.dart';
import '../../tag/tag.dart';
import '../../uid/transfer_syntax.dart';
import '../../vr/vr.dart';
import '../read_options.dart';
import 'ambiguity.dart';
import 'checks.dart';
import 'header.dart';
import 'level.dart';
import 'source_reader.dart';

// The walk: elements, their values and their items, recursively, with the
// state that stops it. The repairs found here are about structure
// (trailingBytes, truncated, valueDropped).

const _item = 0xFFFEE000;
const _itemDelimiter = 0xFFFEE00D;
const _sequenceDelimiter = 0xFFFEE0DD;
const _pixelData = 0x7FE00010;
const _specificCharacterSet = 0x00080005;
const _bitsAllocated = 0x00280100;
const _pixelRepresentation = 0x00280103;
const _undefined = 0xFFFFFFFF;

/// How deep sequences may nest before the data is taken as malformed: a
/// bound that keeps a hostile file from overflowing the stack.
const _maxDepth = 64;

/// What [Walker._readElements] is reading, which decides where it stops.
enum _Scope {
  /// The file meta: stops at the first element outside group 0002.
  meta,

  /// A whole dataset: stops at its end, or before Pixel Data when
  /// [ReadOptions.stopBeforePixels] is set. Only here are values deferred,
  /// and filtered by [ReadOptions.tags].
  dataset,

  /// A defined-length item: stops at its end.
  item,

  /// An undefined-length item: stops after its Item Delimitation Item.
  undefinedItem,
}

/// A value as read: where it ends, its [RawValue] (read or deferred), and
/// for SQ its items.
typedef _Value = ({int valueEnd, RawValue raw, Sequence? sequence});

/// One walk over [source] in [ts]: the file meta, or a whole dataset.
/// Every repair it makes goes into [repairs].
final class Walker {
  Walker(this.source, this.ts, this.options, this.repairs)
      : reader = SourceReader(source, ts.littleEndian);

  final ByteSource source;
  final TransferSyntax ts;
  final ReadOptions options;
  final List<Repair> repairs;
  final SourceReader reader;
  late final headers = HeaderReader(reader, repairs);
  final _ambiguous = AmbiguousVrs();

  /// Set once the data ends early: every level stops reading.
  var _stopped = false;

  /// Set when options left elements out (header-only, `tags`).
  var _filtered = false;

  /// The file meta from [start]: the elements and where the dataset starts.
  ({List<DataElement> elements, int end, bool stopped}) readMeta(int start) {
    final level = Level(explicit: true);
    final end = _readElements(start, source.length, _Scope.meta, level);
    return (elements: level.elements, end: end, stopped: _stopped);
  }

  /// The top-level dataset from [start], its ambiguous VRs settled, and
  /// whether it was read only in part.
  ({List<DataElement> elements, bool partial}) readTop(int start) {
    final level =
        Level(explicit: headers.explicitAt(start, ts.explicitVr, null));
    _readElements(start, source.length, _Scope.dataset, level);
    _ambiguous.settle();
    return (elements: level.elements, partial: _stopped || _filtered);
  }

  /// Reads elements from [start] until [end], or until [scope] says to stop,
  /// into [level]. Returns the offset after the last.
  int _readElements(int start, int end, _Scope scope, Level level) {
    var at = start;
    final groups = GroupLengthCheck(reader, repairs);
    try {
      while (at < end && !_stopped) {
        if (at + 8 > end) {
          // Fewer bytes than a header: pydicom ignores them; reported.
          repairs.add(Repair(RepairKind.trailingBytes, offset: at));
          at = end;
          break;
        }
        final tag = reader.tagAt(at);
        if (scope == _Scope.meta && tag >> 16 != 0x0002) break;
        if (tag == _itemDelimiter) {
          if (scope == _Scope.undefinedItem) {
            groups.close(at);
            return at + 8;
          }
          throw DicomParseException('an Item Delimitation Item outside an item',
              offset: at);
        }
        if (scope == _Scope.dataset &&
            options.stopBeforePixels &&
            tag == _pixelData) {
          _filtered = true;
          groups.abandon(); // its group isn't read to the end
          break;
        }
        groups.enter(tag, at);

        final header = headers.read(at, tag, explicit: level.explicit);
        final value = _readValue(header, level, tag, scope);
        if (value == null) break; // dropped: the data ended inside it
        at = value.valueEnd;
        final element = readElement(Tag(tag), header.vr, value.raw,
            decoded: value.sequence);
        _track(tag, element, value.raw, level);
        if (!_keeps(scope, tag)) {
          _filtered = true;
          continue;
        }
        level.elements.add(element);
        _ambiguous.note(element, header, level);
        checkElement(element, header, repairs);
        groups.found(tag, value.raw, at);
      }
      if (!_stopped) groups.close(at);
    } on Truncated catch (t) {
      _truncate(t);
      return t.at;
    }
    if (scope == _Scope.undefinedItem && !_stopped) {
      // The data ended before the item's delimiter.
      _truncate(Truncated(at, null));
    }
    return at;
  }

  /// Whether an element read in [scope] is kept: [ReadOptions.tags] filters
  /// the top-level dataset only, and always keeps the character set.
  bool _keeps(_Scope scope, int tag) =>
      scope != _Scope.dataset ||
      options.tags == null ||
      options.tags!.contains(Tag(tag)) ||
      tag == _specificCharacterSet;

  void _truncate(Truncated t) {
    if (!_stopped) {
      repairs.add(Repair(RepairKind.truncated,
          tag: t.tag == null ? null : Tag(t.tag!), offset: t.at));
    }
    _stopped = true;
  }

  /// Keeps what later elements need: the character set, and the pixel
  /// attributes implicit VR resolution depends on.
  void _track(int tag, DataElement element, RawValue raw, Level level) {
    switch (tag) {
      case _specificCharacterSet when element.value is List<String>:
        level.charset = element.value as List<String>;
      case _bitsAllocated when raw.length >= 2:
        level.bitsAllocated = reader.u16Of(raw.bytes);
      case _pixelRepresentation when raw.length >= 2:
        level.pixelRepresentation = reader.u16Of(raw.bytes);
    }
  }

  /// Reads the value after [header]. Returns null for an undefined-length
  /// value the data ends inside: dropped, as pydicom drops it.
  _Value? _readValue(ElementHeader header, Level level, int tag, _Scope scope) {
    if (header.vr == Vr.SQ) return _readSequence(header, level, tag);
    final length = header.length;
    final valueStart = header.valueStart;
    final undefined = header.undefinedLength;
    final int valueEnd;
    if (undefined) {
      final end = _fragmentsEnd(valueStart, tag);
      if (end == null) {
        repairs.add(
            Repair(RepairKind.valueDropped, tag: Tag(tag), offset: valueStart));
        _stopped = true;
        return null;
      }
      valueEnd = end;
    } else if (valueStart + length > source.length) {
      // A short value at the end: kept as far as it goes (pydicom keeps the
      // short bytes), and reading stops.
      _truncate(Truncated(valueStart, tag));
      valueEnd = source.length;
    } else {
      valueEnd = valueStart + length;
    }
    final count = valueEnd - valueStart;
    final opener = _openerToDefer(scope, tag, count, undefined: undefined);
    return (
      valueEnd: valueEnd,
      raw: opener != null
          ? RawValue.deferred(opener, valueStart, count,
              undefinedLength: undefined,
              littleEndian: ts.littleEndian,
              specificCharacterSet: level.charset)
          : RawValue(source.read(valueStart, count),
              undefinedLength: undefined,
              littleEndian: ts.littleEndian,
              specificCharacterSet: level.charset),
      sequence: null,
    );
  }

  /// The opener to defer a value of [count] bytes through, or null to read
  /// it now: only top-level values over [ReadOptions.deferSize] are
  /// deferred, never the character set, and nothing once reading stopped.
  SourceOpener? _openerToDefer(_Scope scope, int tag, int count,
      {required bool undefined}) {
    final opener = source.opener;
    final defer = options.deferSize;
    final deferred = scope == _Scope.dataset &&
        !_stopped &&
        opener != null &&
        defer != null &&
        tag != _specificCharacterSet &&
        (undefined ? count >= defer : count > defer);
    return deferred ? opener : null;
  }

  /// Reads an SQ value: its items, and a [RawValue] that holds no bytes (the
  /// writer rebuilds a sequence from its items).
  _Value _readSequence(ElementHeader header, Level level, int tag) {
    final length = header.length;
    final valueStart = header.valueStart;
    final undefined = header.undefinedLength;
    final int valueEnd;
    final List<Dataset> items;
    if (undefined) {
      (items, valueEnd) =
          _readItems(valueStart, null, level, tag, header.itemsImplicit);
    } else {
      final end = valueStart + length;
      (items, _) = _readItems(valueStart, math.min(end, source.length), level,
          tag, header.itemsImplicit);
      if (end > source.length) _truncate(Truncated(source.length, tag));
      valueEnd = math.min(end, source.length);
    }
    return (
      valueEnd: valueEnd,
      raw: RawValue.sequence(
          undefinedLength: undefined,
          littleEndian: ts.littleEndian,
          specificCharacterSet: level.charset),
      sequence: Sequence(items),
    );
  }

  /// Reads SQ items from [start] to [end], or to the Sequence Delimitation
  /// Item when [end] is null. Each item reads as its own level; with
  /// [implicit], as Implicit VR (the items of a UN sequence).
  (List<Dataset>, int) _readItems(
      int start, int? end, Level level, int sequenceTag, bool implicit) {
    if (level.depth >= _maxDepth) {
      throw DicomParseException(
          'sequences nest more than $_maxDepth deep, so the data is taken as '
          'malformed',
          offset: start,
          tag: Tag(sequenceTag));
    }
    final items = <Dataset>[];
    var at = start;
    while ((end == null || at < end) && !_stopped) {
      if (at + 8 > source.length) {
        _truncate(Truncated(at, sequenceTag));
        break;
      }
      final tag = reader.tagAt(at);
      final length = reader.u32(at + 4);
      if (tag == _sequenceDelimiter && end == null) return (items, at + 8);
      if (tag != _item) {
        throw DicomParseException('expected an Item in a sequence',
            offset: at, tag: Tag(sequenceTag));
      }
      final explicit = implicit
          ? false
          : headers.explicitAt(at + 8, level.explicit, sequenceTag);
      final itemLevel = Level.item(level, explicit: explicit);
      if (length == _undefined) {
        at = _readElements(
            at + 8, source.length, _Scope.undefinedItem, itemLevel);
        items.add(
            readDataset(itemLevel.elements, ts.uid, undefinedLength: true));
      } else {
        final itemEnd = math.min(at + 8 + length, source.length);
        _readElements(at + 8, itemEnd, _Scope.item, itemLevel);
        items.add(readDataset(itemLevel.elements, ts.uid));
        if (at + 8 + length > source.length) {
          _truncate(Truncated(source.length, sequenceTag));
        }
        at = itemEnd;
      }
    }
    return (items, at);
  }

  /// Where an undefined-length non-SQ value (encapsulated Pixel Data: an
  /// offset table and fragments) ends: after its Sequence Delimitation
  /// Item; or null if the data ends first.
  int? _fragmentsEnd(int start, int tag) {
    var at = start;
    while (true) {
      if (at + 8 > source.length) return null;
      final itemTag = reader.tagAt(at);
      final length = reader.u32(at + 4);
      if (itemTag == _sequenceDelimiter) return at + 8;
      if (itemTag != _item || length == _undefined) {
        throw DicomParseException('malformed encapsulated value',
            offset: at, tag: Tag(tag));
      }
      if (at + 8 + length > source.length) return null;
      at += 8 + length;
    }
  }
}
