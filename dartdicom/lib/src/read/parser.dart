import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../dataset/dataset.dart';
import '../dataset/element.dart';
import '../dataset/read_report.dart';
import '../dataset/sequence.dart';
import '../dictionary/dictionary.dart';
import '../errors.dart';
import '../source/byte_source.dart';
import '../tag/tag.dart';
import '../tag/tags.g.dart';
import '../uid/transfer_syntax.dart';
import '../uid/uid.dart';
import '../vr/ambiguous.dart';
import '../vr/value_codec.dart' show numberSize;
import '../vr/vr.dart';
import 'inflate.dart';
import 'read_options.dart';

// A synchronous walk over a ByteSource (design D1). It slices values without
// decoding them; each element decodes itself on first access (C-05). SQ items
// are parsed here, into datasets of their own; a sequence keeps no bytes of
// its own, and the writer rebuilds it from its items. A value longer than
// ReadOptions.deferSize isn't read at all: it loads through the source's
// opener on first access.
//
// Reading is lenient (C-10), following pydicom 3.0.2: real-world data is
// repaired where it can be, and every repair goes into the ReadReport.

const _item = 0xFFFEE000;
const _itemDelimiter = 0xFFFEE00D;
const _sequenceDelimiter = 0xFFFEE0DD;
const _pixelData = 0x7FE00010;
const _specificCharacterSet = 0x00080005;
const _bitsAllocated = 0x00280100;
const _pixelRepresentation = 0x00280103;
const _waveformBitsAllocated = 0x54001004;
const _lutDescriptor = 0x00283002;
const _undefined = 0xFFFFFFFF;

/// How deep sequences may nest before the data is taken as malformed: a
/// bound that keeps a hostile file from overflowing the stack.
const _maxDepth = 64;

/// A Part 10 file split into its parts, and what reading it repaired.
typedef Part10 = ({
  Dataset meta,
  Dataset dataset,
  Uint8List preamble,
  ReadReport report,
});

/// Parses a Part 10 file: the 128-byte preamble, `DICM`, the file meta
/// group in Explicit VR Little Endian, then the dataset in the transfer
/// syntax the meta declares (PS3.10 §7.1).
///
/// With [ReadOptions.force], data with no preamble is read too: file meta
/// from offset 0 if it is there, else a bare dataset whose syntax is
/// detected from the bytes.
Part10 parsePart10(ByteSource source, ReadOptions options) {
  final repairs = <Repair>[];
  final head = source.read(0, math.min(132, source.length));
  final hasPrefix = head.length == 132 &&
      latin1.decode(Uint8List.sublistView(head, 128, 132)) == 'DICM';
  var metaStart = 132;
  if (!hasPrefix) {
    if (!options.force) {
      throw DicomParseException(
          'no DICM prefix at byte 128, so this is not a Part 10 file; pass '
          'ReadOptions(force: true) to read it anyway',
          offset: 128);
    }
    repairs.add(const Repair(RepairKind.noPreamble, offset: 0));
    metaStart = 0;
  }
  final preamble = hasPrefix
      ? Uint8List.fromList(Uint8List.sublistView(head, 0, 128))
      : Uint8List(128);

  final meta =
      _Parser(source, TransferSyntax.explicitVrLittleEndian, options, repairs)
          .readMeta(metaStart);
  final bodyStart = meta.end;
  final metaDataset =
      readDataset(meta.elements, TransferSyntax.explicitVrLittleEndian.uid);

  final TransferSyntax ts;
  final tsUid = metaDataset.get(DicomTags.transferSyntaxUid);
  if (tsUid != null) {
    ts = TransferSyntax.of(Uid(tsUid)) ??
        (throw DicomParseException(
            'transfer syntax $tsUid is not a registered one, so the data '
            'cannot be decoded',
            offset: bodyStart));
  } else {
    repairs.add(Repair(
        meta.elements.isEmpty
            ? RepairKind.noFileMeta
            : RepairKind.syntaxDetected,
        offset: bodyStart));
    ts = _detectSyntax(source, bodyStart);
  }
  // The data ended inside the meta: there is no dataset to read.
  final dataset = meta.stopped
      ? readDataset(const [], ts.uid,
          partial: true, report: ReadReport(repairs))
      : parseDataset(source, ts, options, bodyStart, repairs);
  return (
    meta: metaDataset,
    dataset: dataset,
    preamble: preamble,
    report: ReadReport(repairs),
  );
}

/// Parses a bare dataset (no preamble or file meta) encoded in [ts], from
/// [start]: e.g. a DIMSE identifier. Repairs are added to [repairs]; without
/// it, the dataset carries its own report.
Dataset parseDataset(ByteSource source, TransferSyntax ts, ReadOptions options,
    [int start = 0, List<Repair>? repairs]) {
  final found = repairs ?? <Repair>[];
  if (ts.deflated) {
    // Everything after the meta is one raw DEFLATE stream (PS3.5 §A.5);
    // inflated, it is Explicit VR Little Endian. Nothing is deferred: the
    // inflated bytes are in memory.
    final Uint8List inflated;
    try {
      inflated = (options.deflateCodec ?? const PureDartInflate())
          .inflate(source.read(start, source.length - start));
    } on FormatException catch (e) {
      throw DicomParseException(
          'the Deflated dataset is malformed (${e.message})',
          offset: start);
    }
    source = BytesSource(inflated);
    start = 0;
  }
  final (:elements, :partial) =
      _Parser(source, ts, options, found).readTop(start);
  return readDataset(elements, ts.uid,
      partial: partial, report: ReadReport(found));
}

/// pydicom's detection, when no syntax is declared: two letters at offset 4
/// mean Explicit VR; a little-endian group of 1024 or more means the data
/// is Big Endian.
TransferSyntax _detectSyntax(ByteSource source, int at) {
  if (at + 8 > source.length) return TransferSyntax.implicitVrLittleEndian;
  final b = source.read(at, 8);
  final group = b[0] | b[1] << 8;
  final explicit = _isLetter(b[4]) && _isLetter(b[5]);
  if (group >= 1024 && explicit) return TransferSyntax.explicitVrBigEndian;
  return explicit
      ? TransferSyntax.explicitVrLittleEndian
      : TransferSyntax.implicitVrLittleEndian;
}

bool _isLetter(int b) => b >= 0x41 && b <= 0x5A;

/// What [_Parser._readElements] is reading, which decides where it stops.
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

/// One dataset level being read: what later elements need from earlier
/// ones, and the elements read so far (for settling ambiguous VRs once the
/// level is complete).
final class _Level {
  _Level({required this.explicit})
      : charset = const [],
        parent = null,
        depth = 0;

  /// An item's level: it starts from its sequence's state, and what it
  /// reads stays inside it.
  _Level.item(_Level this.parent, {required this.explicit})
      : charset = parent.charset,
        bitsAllocated = parent.bitsAllocated,
        pixelRepresentation = parent.pixelRepresentation,
        depth = parent.depth + 1;

  final _Level? parent;
  final int depth;

  /// Whether this level is read as Explicit VR. It can differ from the
  /// transfer syntax: an item can be implicit, and UN→SQ items are.
  final bool explicit;
  List<String> charset;
  int? bitsAllocated;
  int? pixelRepresentation;
  final elements = <DataElement>[];
}

/// Thrown where the data ends inside an element: reading stops, and keeps
/// what came before.
final class _Truncated implements Exception {
  const _Truncated(this.at, this.tag);
  final int at;
  final int? tag;
}

/// An element whose VR came from an ambiguous dictionary entry, settled once
/// its level is complete.
typedef _Ambiguous = ({
  DataElement element,
  List<Vr> vrs,
  _Level level,
  bool implicit,
  bool undefinedLength,
});

final class _Parser {
  _Parser(this.source, this.ts, this.options, this.repairs)
      : endian = ts.littleEndian ? Endian.little : Endian.big;

  final ByteSource source;
  final TransferSyntax ts;
  final Endian endian;
  final ReadOptions options;
  final List<Repair> repairs;
  final _ambiguous = <_Ambiguous>[];

  /// Set once the data ends early: every level stops reading.
  var _stopped = false;

  /// Set when options left elements out (header-only, `tags`).
  var _filtered = false;

  /// The file meta from [start]: the elements and where the dataset starts.
  ({List<DataElement> elements, int end, bool stopped}) readMeta(int start) {
    final level = _Level(explicit: true);
    final end = _readElements(start, source.length, _Scope.meta, level);
    return (elements: level.elements, end: end, stopped: _stopped);
  }

  /// The top-level dataset from [start], its ambiguous VRs settled, and
  /// whether it was read only in part.
  ({List<DataElement> elements, bool partial}) readTop(int start) {
    final level = _Level(explicit: _explicitAt(start, ts.explicitVr, null));
    _readElements(start, source.length, _Scope.dataset, level);
    _settleAmbiguous();
    return (elements: level.elements, partial: _stopped || _filtered);
  }

  /// Whether the data at [at] reads as Explicit VR: two letters where the
  /// VR would be. If that contradicts [expected], the data wins and the
  /// contradiction is reported (pydicom checks at the dataset start and at
  /// each item).
  bool _explicitAt(int at, bool expected, int? sequenceTag) {
    if (at + 8 > source.length) return expected;
    final tag = _tagAt(at);
    // A delimiter or an empty item has no VR to look at.
    if (tag >> 16 == 0xFFFE) return expected;
    final b = source.read(at + 4, 2);
    final explicit = _isLetter(b[0]) && _isLetter(b[1]);
    if (explicit != expected) {
      repairs.add(Repair(RepairKind.syntaxContradicted,
          tag: Tag(sequenceTag ?? tag), offset: at));
    }
    return explicit;
  }

  /// Reads elements from [start] until [end], or until [scope] says to stop,
  /// into [level]. Returns the offset after the last.
  int _readElements(int start, int end, _Scope scope, _Level level) {
    var at = start;
    // The group length being checked against its group (staleGroupLength).
    int? group;
    int? groupStart;
    int? groupLength;
    void closeGroup(int upTo) {
      if (groupStart != null && groupLength != upTo - groupStart!) {
        repairs.add(Repair(RepairKind.staleGroupLength,
            tag: Tag.of(group!, 0), offset: groupStart));
      }
      groupStart = null;
    }

    try {
      while (at < end && !_stopped) {
        if (at + 8 > end) {
          // Fewer bytes than a header: pydicom ignores them; reported.
          repairs.add(Repair(RepairKind.trailingBytes, offset: at));
          at = end;
          break;
        }
        final tag = _tagAt(at);
        if (scope == _Scope.meta && tag >> 16 != 0x0002) break;
        if (tag == _itemDelimiter) {
          if (scope == _Scope.undefinedItem) {
            closeGroup(at);
            return at + 8;
          }
          throw DicomParseException('an Item Delimitation Item outside an item',
              offset: at);
        }
        if (scope == _Scope.dataset &&
            options.stopBeforePixels &&
            tag == _pixelData) {
          _filtered = true;
          groupStart = null; // its group isn't read to the end
          break;
        }
        if (tag >> 16 != group) {
          closeGroup(at);
          group = tag >> 16;
        }

        final header = _readHeader(at, tag, level);
        final value = _readValue(header, level, tag, scope);
        if (value == null) break; // dropped: the data ended inside it
        at = value.valueEnd;
        final element = readElement(Tag(tag), header.vr, value.raw,
            decoded: value.sequence);
        _track(tag, element, value.raw, level);
        final keep = scope != _Scope.dataset ||
            options.tags == null ||
            options.tags!.contains(Tag(tag)) ||
            tag == _specificCharacterSet;
        if (!keep) {
          _filtered = true;
          continue;
        }
        level.elements.add(element);
        if (header.ambiguous case final vrs?) {
          _ambiguous.add((
            element: element,
            vrs: vrs,
            level: level,
            implicit: !level.explicit,
            undefinedLength: header.length == _undefined,
          ));
        }
        _check(element, header);
        if (tag & 0xFFFF == 0x0000 && value.raw.length == 4) {
          groupStart = at;
          groupLength = _u32Of(value.raw.bytes);
        }
      }
      if (!_stopped) closeGroup(at);
    } on _Truncated catch (t) {
      _truncate(t);
      return t.at;
    }
    if (scope == _Scope.undefinedItem && !_stopped) {
      // The data ended before the item's delimiter.
      _truncate(_Truncated(at, null));
    }
    return at;
  }

  void _truncate(_Truncated t) {
    if (!_stopped) {
      repairs.add(Repair(RepairKind.truncated,
          tag: t.tag == null ? null : Tag(t.tag!), offset: t.at));
    }
    _stopped = true;
  }

  /// Keeps what later elements need: the character set, and the pixel
  /// attributes implicit VR resolution depends on.
  void _track(int tag, DataElement element, RawValue raw, _Level level) {
    switch (tag) {
      case _specificCharacterSet when element.value is List<String>:
        level.charset = element.value as List<String>;
      case _bitsAllocated when raw.length >= 2:
        level.bitsAllocated = _u16Of(raw.bytes);
      case _pixelRepresentation when raw.length >= 2:
        level.pixelRepresentation = _u16Of(raw.bytes);
    }
  }

  /// The C-10 checks that leave an element as it is but report it: a
  /// numeric length that doesn't fit the VR, several values where the
  /// dictionary allows one (DA1, checked on the raw bytes so reads stay
  /// lazy).
  void _check(DataElement element, _Header header) {
    final length = header.length;
    if (length == _undefined || length == 0) return;
    final vr = element.vr;
    final size = numberSize(vr);
    if (size != null && length % size != 0) {
      repairs.add(Repair(RepairKind.wrongLength,
          tag: element.tag, offset: header.valueStart));
    }
    if (Dictionary.standard.entry(element.tag)?.vm != '1') return;
    final raw = rawValueOf(element)!;
    final several = size != null
        ? length >= 2 * size
        : _multiValueText.contains(vr) &&
            !raw.isDeferred &&
            raw.bytes.contains(0x5C);
    if (several) {
      repairs.add(Repair(RepairKind.multipleValues,
          tag: element.tag, offset: header.valueStart));
    }
  }

  /// Reads the header of the element at [at], whose tag is [tag].
  _Header _readHeader(int at, int tag, _Level level) {
    if (!level.explicit) return _implicitHeader(at, tag);
    _need(at, 8, tag);
    final code = source.read(at + 4, 2);
    if (!_isLetter(code[0]) || !_isLetter(code[1])) {
      // No VR where Explicit VR data has one: read this element as
      // implicit (pydicom does the same, silently).
      repairs
          .add(Repair(RepairKind.implicitElement, tag: Tag(tag), offset: at));
      return _implicitHeader(at, tag);
    }
    var vr = Vr.fromCode(latin1.decode(code));
    final int length;
    final int valueStart;
    if (vr == null) {
      repairs.add(Repair(RepairKind.unknownVr, tag: Tag(tag), offset: at));
      vr = Vr.UN;
      length = _u16(at + 6);
      valueStart = at + 8;
    } else if (vr.hasLongLength) {
      _need(at, 12, tag);
      length = _u32(at + 8);
      valueStart = at + 12;
    } else {
      length = _u16(at + 6);
      valueStart = at + 8;
    }
    if (vr == Vr.UN) return _unknownValue(at, tag, length, valueStart);
    return _Header(vr, length, valueStart);
  }

  _Header _implicitHeader(int at, int tag) {
    final length = _u32(at + 4);
    final (vr, ambiguous) = _dictionaryVr(Tag(tag));
    // A tag the dictionary doesn't know, with an undefined length, can only
    // be a sequence (PS3.5 §7.5.1); its items are Implicit VR too.
    if (vr == Vr.UN && length == _undefined) {
      return _Header(Vr.SQ, length, at + 8, itemsImplicit: true);
    }
    return _Header(vr, length, at + 8, ambiguous: ambiguous);
  }

  /// An explicit UN: given the dictionary's VR if it knows one (pydicom's
  /// `replace_un_with_known_vr`), or read as an SQ of Implicit VR items if
  /// its length is undefined (PS3.5 §6.2.2).
  _Header _unknownValue(int at, int tag, int length, int valueStart) {
    final t = Tag(tag);
    if (length == _undefined) {
      repairs.add(Repair(RepairKind.unSequence, tag: t, offset: at));
      return _Header(Vr.SQ, length, valueStart, itemsImplicit: true);
    }
    final (vr, ambiguous) = _dictionaryVr(t);
    final known =
        vr != Vr.UN && length < 0xFFFF && (!t.isPrivate || vr == Vr.LO);
    if (!known) return _Header(Vr.UN, length, valueStart);
    repairs.add(Repair(RepairKind.unReplaced, tag: t, offset: at));
    // A UN value is in Implicit VR terms, an SQ's items included.
    return _Header(vr, length, valueStart,
        ambiguous: ambiguous, itemsImplicit: vr == Vr.SQ);
  }

  /// The VR the dictionary gives [tag] (LO for a private creator, UL for a
  /// group length, UN for an unknown tag), and its VRs when it gives
  /// several, to settle once the level is read.
  (Vr, List<Vr>?) _dictionaryVr(Tag tag) {
    if (tag.element == 0x0000) return (Vr.UL, null);
    if (tag.isPrivate && tag.element >= 0x0010 && tag.element <= 0x00FF) {
      return (Vr.LO, null);
    }
    final entry = Dictionary.standard.entry(tag);
    if (entry == null || entry.vrs.isEmpty) return (Vr.UN, null);
    if (entry.vrs.length == 1) return (entry.vrs.single, null);
    return (entry.vrs.first, entry.vrs);
  }

  /// Reads the value after [header]: where it ends, its [RawValue] (read or
  /// deferred), and for SQ its items. Returns null for an undefined-length
  /// value the data ends inside: dropped, as pydicom drops it.
  ({int valueEnd, RawValue raw, Sequence? sequence})? _readValue(
      _Header header, _Level level, int tag, _Scope scope) {
    final length = header.length;
    final valueStart = header.valueStart;
    final undefined = length == _undefined;
    if (header.vr == Vr.SQ) {
      final int valueEnd;
      final List<Dataset> items;
      if (undefined) {
        (items, valueEnd) =
            _readItems(valueStart, null, level, tag, header.itemsImplicit);
      } else {
        final end = valueStart + length;
        (items, _) = _readItems(valueStart, math.min(end, source.length), level,
            tag, header.itemsImplicit);
        if (end > source.length) _truncate(_Truncated(source.length, tag));
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
      _truncate(_Truncated(valueStart, tag));
      valueEnd = source.length;
    } else {
      valueEnd = valueStart + length;
    }
    final count = valueEnd - valueStart;
    final opener = source.opener;
    final defer = options.deferSize;
    final deferred = scope == _Scope.dataset &&
        !_stopped &&
        opener != null &&
        defer != null &&
        tag != _specificCharacterSet &&
        (undefined ? count >= defer : count > defer);
    return (
      valueEnd: valueEnd,
      raw: deferred
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

  /// Reads SQ items from [start] to [end], or to the Sequence Delimitation
  /// Item when [end] is null. Each item reads as its own level; with
  /// [implicit], as Implicit VR (the items of a UN sequence).
  (List<Dataset>, int) _readItems(
      int start, int? end, _Level level, int sequenceTag, bool implicit) {
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
        _truncate(_Truncated(at, sequenceTag));
        break;
      }
      final tag = _tagAt(at);
      final length = _u32(at + 4);
      if (tag == _sequenceDelimiter && end == null) return (items, at + 8);
      if (tag != _item) {
        throw DicomParseException('expected an Item in a sequence',
            offset: at, tag: Tag(sequenceTag));
      }
      final explicit =
          implicit ? false : _explicitAt(at + 8, level.explicit, sequenceTag);
      final itemLevel = _Level.item(level, explicit: explicit);
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
          _truncate(_Truncated(source.length, sequenceTag));
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
      final itemTag = _tagAt(at);
      final length = _u32(at + 4);
      if (itemTag == _sequenceDelimiter) return at + 8;
      if (itemTag != _item || length == _undefined) {
        throw DicomParseException('malformed encapsulated value',
            offset: at, tag: Tag(tag));
      }
      if (at + 8 + length > source.length) return null;
      at += 8 + length;
    }
  }

  /// Settles each ambiguous VR now that its level, and the levels around
  /// it, are complete (pydicom's rules: `resolveReadVr`).
  void _settleAmbiguous() {
    int? firstInt(List<DataElement> elements, int tag) {
      final value =
          elements.where((e) => e.tag.value == tag).firstOrNull?.value;
      return value is List<int> && value.isNotEmpty ? value.first : null;
    }

    for (final a in _ambiguous) {
      int? pixelRepresentation;
      for (_Level? l = a.level; l != null; l = l.parent) {
        pixelRepresentation = firstInt(l.elements, _pixelRepresentation);
        if (pixelRepresentation != null) break;
      }
      final vr = resolveReadVr(a.element.tag.value, a.vrs, (
        implicit: a.implicit,
        undefinedLength: a.undefinedLength,
        bitsAllocated: firstInt(a.level.elements, _bitsAllocated),
        pixelRepresentation: pixelRepresentation,
        hasPixelData: a.level.elements.any((e) => e.tag.value == _pixelData),
        waveformBitsAllocated:
            firstInt(a.level.elements, _waveformBitsAllocated),
        lutDescriptorFirst: firstInt(a.level.elements, _lutDescriptor),
      ));
      if (vr != null && vr != a.element.vr) retypeElement(a.element, vr);
    }
  }

  ByteData _data(int at, int n) => ByteData.sublistView(source.read(at, n));

  int _u16(int at) {
    _need(at, 2, null);
    return _data(at, 2).getUint16(0, endian);
  }

  int _u32(int at) {
    _need(at, 4, null);
    return _data(at, 4).getUint32(0, endian);
  }

  int _u16Of(Uint8List bytes) =>
      ByteData.sublistView(bytes).getUint16(0, endian);

  int _u32Of(Uint8List bytes) =>
      ByteData.sublistView(bytes).getUint32(0, endian);

  int _tagAt(int at) {
    _need(at, 4, null);
    final d = _data(at, 4);
    return d.getUint16(0, endian) << 16 | d.getUint16(2, endian);
  }

  void _need(int at, int n, int? tag) {
    if (at + n > source.length) throw _Truncated(at, tag);
  }
}

/// An element header: its VR, value length and where the value starts; the
/// ambiguous dictionary VRs still to settle, and whether its SQ items are
/// implicit.
final class _Header {
  _Header(this.vr, this.length, this.valueStart,
      {this.ambiguous, this.itemsImplicit = false});

  final Vr vr;
  final int length;
  final int valueStart;
  final List<Vr>? ambiguous;
  final bool itemsImplicit;
}

/// Text VRs that can hold several values, split on backslash.
const _multiValueText = {
  Vr.AE, Vr.AS, Vr.CS, Vr.DA, Vr.DS, Vr.DT, Vr.IS, Vr.LO, Vr.PN, //
  Vr.SH, Vr.TM, Vr.UC, Vr.UI,
};
