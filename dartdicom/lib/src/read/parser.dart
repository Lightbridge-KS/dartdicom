import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../dataset/dataset.dart';
import '../dataset/element.dart';
import '../dataset/sequence.dart';
import '../dictionary/dictionary.dart';
import '../errors.dart';
import '../source/byte_source.dart';
import '../tag/tag.dart';
import '../tag/tags.g.dart';
import '../uid/transfer_syntax.dart';
import '../uid/uid.dart';
import '../vr/ambiguous.dart';
import '../vr/vr.dart';
import 'inflate.dart';
import 'read_options.dart';

// A synchronous walk over a ByteSource (design D1). It slices values without
// decoding them; each element decodes itself on first access (C-05). SQ items
// are parsed here, into datasets of their own; a sequence keeps no bytes of
// its own, and the writer rebuilds it from its items. A value longer than
// ReadOptions.deferSize isn't read at all: it loads through the source's
// opener on first access.

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

/// A Part 10 file split into its two parts: group 0002 and the dataset.
typedef Part10 = ({Dataset meta, Dataset dataset, Uint8List preamble});

/// Parses a Part 10 file: the 128-byte preamble, `DICM`, the file meta
/// group in Explicit VR Little Endian, then the dataset in the transfer
/// syntax the meta declares (PS3.10 §7.1).
Part10 parsePart10(ByteSource source, ReadOptions options) {
  final head = source.length < 132 ? null : source.read(0, 132);
  if (head == null ||
      latin1.decode(Uint8List.sublistView(head, 128, 132)) != 'DICM') {
    throw DicomParseException(
        'no DICM prefix at byte 128, so this is not a Part 10 file',
        offset: 128);
  }
  final preamble = Uint8List.fromList(Uint8List.sublistView(head, 0, 128));
  final metaParser =
      _Parser(source, TransferSyntax.explicitVrLittleEndian, options);
  final (metaElements, bodyStart, _) =
      metaParser.readElements(132, source.length, _Scope.meta, _Context());
  final meta =
      readDataset(metaElements, TransferSyntax.explicitVrLittleEndian.uid);
  final tsUid = meta.get(DicomTags.transferSyntaxUid);
  if (tsUid == null) {
    throw DicomParseException(
        'the file meta has no (0002,0010) TransferSyntaxUID',
        offset: bodyStart);
  }
  final ts = _supported(Uid(tsUid), bodyStart);
  return (
    meta: meta,
    dataset: parseDataset(source, ts, options, bodyStart),
    preamble: preamble,
  );
}

/// Parses a bare dataset (no preamble or file meta) encoded in [ts], from
/// [start]: e.g. a DIMSE identifier.
Dataset parseDataset(ByteSource source, TransferSyntax ts, ReadOptions options,
    [int start = 0]) {
  _supported(ts.uid, start);
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
  final (elements, _, partial) = _Parser(source, ts, options)
      .readElements(start, source.length, _Scope.dataset, _Context());
  return readDataset(elements, ts.uid, partial: partial);
}

TransferSyntax _supported(Uid uid, int offset) {
  final ts = TransferSyntax.of(uid);
  if (ts == null || !ts.littleEndian) {
    throw DicomParseException(
        'transfer syntax ${uid.value} is not supported for reading yet '
        '(supported: Implicit, Explicit and Deflated Explicit VR Little '
        'Endian, and the encapsulated forms)',
        offset: offset);
  }
  return ts;
}

/// What [_Parser.readElements] is reading, which decides where it stops.
enum _Scope {
  /// The file meta: stops at the first element outside group 0002.
  meta,

  /// A whole dataset: stops at its end, or before Pixel Data when
  /// [ReadOptions.stopBeforePixels] is set. Only here are values deferred.
  dataset,

  /// A defined-length item: stops at its end.
  item,

  /// An undefined-length item: stops after its Item Delimitation Item.
  undefinedItem,
}

/// What later elements need from earlier ones: the character set for
/// text, and the pixel attributes implicit VR resolution needs.
final class _Context {
  _Context() : charset = const [];

  /// A copy of [parent] for an item: the item sees what its sequence's
  /// dataset read before it, and what the item reads stays inside it.
  _Context.inherit(_Context parent)
      : charset = parent.charset,
        bitsAllocated = parent.bitsAllocated,
        pixelRepresentation = parent.pixelRepresentation,
        depth = parent.depth + 1;

  List<String> charset;
  int? bitsAllocated;
  int? pixelRepresentation;

  /// How many sequences enclose what is being read.
  int depth = 0;
}

final class _Parser {
  _Parser(this.source, this.ts, this.options)
      : endian = ts.littleEndian ? Endian.little : Endian.big;

  final ByteSource source;
  final TransferSyntax ts;
  final Endian endian;
  final ReadOptions options;

  /// Reads elements from [start] until [end], or until [scope] says to stop,
  /// keeping [context] up to date. Returns them, the offset after the last,
  /// and whether reading stopped early (a partial read).
  (List<DataElement>, int, bool) readElements(
      int start, int end, _Scope scope, _Context context) {
    final elements = <DataElement>[];
    var at = start;
    while (at < end) {
      _need(at, 8, null);
      final tag = _tagAt(at);
      if (scope == _Scope.meta && tag >> 16 != 0x0002) break;
      if (tag == _itemDelimiter) {
        if (scope == _Scope.undefinedItem) return (elements, at + 8, false);
        throw DicomParseException('an Item Delimitation Item outside an item',
            offset: at);
      }
      if (scope == _Scope.dataset &&
          options.stopBeforePixels &&
          tag == _pixelData) {
        return (elements, at, true);
      }

      final (:vr, :length, :valueStart) = _readHeader(at, tag, context);
      final (:valueEnd, :raw, :sequence) =
          _readValue(valueStart, length, vr, context, tag, scope);
      final element = readElement(Tag(tag), vr, raw, decoded: sequence);
      elements.add(element);

      switch (tag) {
        // Written as UN, (0008,0005) holds bytes: step 5's repair gives it
        // its dictionary VR; until then the default repertoire stands.
        case _specificCharacterSet when element.value is List<String>:
          context.charset = element.value as List<String>;
        case _bitsAllocated when length >= 2:
          context.bitsAllocated = _u16Of(raw.bytes);
        case _pixelRepresentation when length >= 2:
          context.pixelRepresentation = _u16Of(raw.bytes);
      }
      at = valueEnd;
    }
    if (scope == _Scope.undefinedItem) {
      throw DicomParseException(
          'an undefined-length item has no Item Delimitation Item',
          offset: at);
    }
    return (elements, at, false);
  }

  /// Reads the header of the element at [at], whose tag is [tag]: its VR,
  /// its value length, and where its value starts.
  ({Vr vr, int length, int valueStart}) _readHeader(
      int at, int tag, _Context context) {
    if (ts.explicitVr) {
      final code = latin1.decode(source.read(at + 4, 2));
      final vr = Vr.fromCode(code);
      if (vr == null) {
        throw DicomParseException('unknown VR code in an explicit VR element',
            offset: at + 4, tag: Tag(tag));
      }
      if (vr.hasLongLength) {
        _need(at, 12, tag);
        return (vr: vr, length: _u32(at + 8), valueStart: at + 12);
      }
      return (vr: vr, length: _u16(at + 6), valueStart: at + 8);
    }
    final length = _u32(at + 4);
    final known = _implicitVr(Tag(tag), context);
    // A tag the dictionary doesn't know, with an undefined length, can only
    // be a sequence (PS3.5 §7.5.1).
    final vr = known == Vr.UN && length == _undefined ? Vr.SQ : known;
    return (vr: vr, length: length, valueStart: at + 8);
  }

  /// Reads the value from [valueStart]: where it ends, its [RawValue] (read,
  /// or deferred), and for SQ the items, parsed into datasets.
  ({int valueEnd, RawValue raw, Sequence? sequence}) _readValue(int valueStart,
      int length, Vr vr, _Context context, int tag, _Scope scope) {
    final undefined = length == _undefined;
    if (vr == Vr.SQ) {
      final (items, valueEnd) = undefined
          ? _readItems(valueStart, null, context, tag)
          : _readDefinedItems(valueStart, length, context, tag);
      return (
        valueEnd: valueEnd,
        raw: RawValue.sequence(
            undefinedLength: undefined,
            littleEndian: ts.littleEndian,
            specificCharacterSet: context.charset),
        sequence: Sequence(items),
      );
    }
    final valueEnd =
        undefined ? _skipFragments(valueStart, tag) : valueStart + length;
    if (!undefined) _need(valueStart, length, tag);
    final count = valueEnd - valueStart;
    final opener = source.opener;
    final defer = options.deferSize;
    final deferred = scope == _Scope.dataset &&
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
              specificCharacterSet: context.charset)
          : RawValue(source.read(valueStart, count),
              undefinedLength: undefined,
              littleEndian: ts.littleEndian,
              specificCharacterSet: context.charset),
      sequence: null,
    );
  }

  (List<Dataset>, int) _readDefinedItems(
      int start, int length, _Context context, int tag) {
    _need(start, length, tag);
    final (items, _) = _readItems(start, start + length, context, tag);
    return (items, start + length);
  }

  /// Reads SQ items from [start] to [end], or to the Sequence Delimitation
  /// Item when [end] is null. Each item reads with a copy of [context].
  (List<Dataset>, int) _readItems(
      int start, int? end, _Context context, int sequenceTag) {
    if (context.depth >= _maxDepth) {
      throw DicomParseException(
          'sequences nest more than $_maxDepth deep, so the data is taken as '
          'malformed',
          offset: start,
          tag: Tag(sequenceTag));
    }
    final items = <Dataset>[];
    var at = start;
    while (end == null || at < end) {
      final (:tag, :length) = _readItemHeader(at, sequenceTag);
      if (tag == _sequenceDelimiter && end == null) return (items, at + 8);
      if (tag != _item) {
        throw DicomParseException('expected an Item in a sequence',
            offset: at, tag: Tag(sequenceTag));
      }
      final itemContext = _Context.inherit(context);
      if (length == _undefined) {
        final (elements, after, _) = readElements(
            at + 8, source.length, _Scope.undefinedItem, itemContext);
        items.add(readDataset(elements, ts.uid, undefinedLength: true));
        at = after;
      } else {
        _need(at + 8, length, sequenceTag);
        final (elements, _, _) =
            readElements(at + 8, at + 8 + length, _Scope.item, itemContext);
        items.add(readDataset(elements, ts.uid));
        at += 8 + length;
      }
    }
    return (items, at);
  }

  /// Skips the items of an undefined-length non-SQ value (encapsulated Pixel
  /// Data: an offset table and fragments), returning the offset after its
  /// Sequence Delimitation Item.
  int _skipFragments(int start, int tag) {
    var at = start;
    while (true) {
      final (tag: itemTag, :length) = _readItemHeader(at, tag);
      if (itemTag == _sequenceDelimiter) return at + 8;
      if (itemTag != _item || length == _undefined) {
        throw DicomParseException('malformed encapsulated value',
            offset: at, tag: Tag(tag));
      }
      _need(at + 8, length, tag);
      at += 8 + length;
    }
  }

  /// Reads the item header at [at], inside the element [ownerTag]: an Item
  /// or delimitation tag, and its length.
  ({int tag, int length}) _readItemHeader(int at, int ownerTag) {
    _need(at, 8, ownerTag);
    return (tag: _tagAt(at), length: _u32(at + 4));
  }

  Vr _implicitVr(Tag tag, _Context context) {
    if (tag.element == 0x0000) return Vr.UL; // group length
    if (tag.isPrivate && tag.element >= 0x0010 && tag.element <= 0x00FF) {
      return Vr.LO; // private creator
    }
    final entry = Dictionary.standard.entry(tag);
    if (entry == null || entry.vrs.isEmpty) return Vr.UN;
    return resolveVr(entry.vrs,
        bitsAllocated: context.bitsAllocated,
        pixelRepresentation: context.pixelRepresentation);
  }

  ByteData _data(int at, int n) => ByteData.sublistView(source.read(at, n));
  int _u16(int at) => _data(at, 2).getUint16(0, endian);
  int _u32(int at) => _data(at, 4).getUint32(0, endian);
  int _u16Of(Uint8List bytes) =>
      ByteData.sublistView(bytes).getUint16(0, endian);

  int _tagAt(int at) {
    final d = _data(at, 4);
    return d.getUint16(0, endian) << 16 | d.getUint16(2, endian);
  }

  void _need(int at, int n, int? tag) {
    if (at + n > source.length) {
      throw DicomParseException('the data ends inside an element',
          offset: math.min(at, source.length),
          tag: tag == null ? null : Tag(tag));
    }
  }
}
