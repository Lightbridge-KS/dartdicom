import 'dart:convert';
import 'dart:typed_data';

import '../dataset/dataset.dart';
import '../dataset/element.dart';
import '../dataset/sequence.dart';
import '../dictionary/dictionary.dart';
import '../errors.dart';
import '../tag/tag.dart';
import '../tag/tags.g.dart';
import '../uid/transfer_syntax.dart';
import '../uid/uid.dart';
import '../vr/ambiguous.dart';
import '../vr/vr.dart';
import 'read_options.dart';

// A synchronous walk over bytes (design D1). It slices values without
// decoding them; each element decodes itself on first access (C-05). SQ
// items are parsed here, in place, so every element keeps its raw bytes and
// nested offsets stay absolute.

const _item = 0xFFFEE000;
const _itemDelimiter = 0xFFFEE00D;
const _sequenceDelimiter = 0xFFFEE0DD;
const _pixelData = 0x7FE00010;
const _specificCharacterSet = 0x00080005;
const _bitsAllocated = 0x00280100;
const _pixelRepresentation = 0x00280103;
const _undefined = 0xFFFFFFFF;

/// A Part 10 file split into its two parts: group 0002 and the dataset.
typedef Part10 = ({Dataset meta, Dataset dataset});

/// Parses a Part 10 file: the 128-byte preamble, `DICM`, the file meta
/// group in Explicit VR Little Endian, then the dataset in the transfer
/// syntax the meta declares (PS3.10 §7.1).
Part10 parsePart10(Uint8List bytes, ReadOptions options) {
  if (bytes.length < 132 ||
      latin1.decode(Uint8List.sublistView(bytes, 128, 132)) != 'DICM') {
    throw DicomParseException(
        'no DICM prefix at byte 128, so this is not a Part 10 file',
        offset: 128);
  }
  final metaParser =
      _Parser(bytes, TransferSyntax.explicitVrLittleEndian, options);
  final (metaElements, bodyStart) =
      metaParser.readElements(132, bytes.length, _Scope.meta, _Context());
  final meta =
      readDataset(metaElements, TransferSyntax.explicitVrLittleEndian.uid);
  final tsUid = meta.get(DicomTags.transferSyntaxUid);
  if (tsUid == null) {
    throw DicomParseException(
        'the file meta has no (0002,0010) TransferSyntaxUID',
        offset: bodyStart);
  }
  final ts = _supported(Uid(tsUid), bodyStart);
  return (meta: meta, dataset: parseDataset(bytes, ts, options, bodyStart));
}

/// Parses a bare dataset (no preamble or file meta) encoded in [ts], from
/// [start]: e.g. a DIMSE identifier.
Dataset parseDataset(Uint8List bytes, TransferSyntax ts, ReadOptions options,
    [int start = 0]) {
  _supported(ts.uid, start);
  final (elements, _) = _Parser(bytes, ts, options)
      .readElements(start, bytes.length, _Scope.dataset, _Context());
  return readDataset(elements, ts.uid);
}

TransferSyntax _supported(Uid uid, int offset) {
  final ts = TransferSyntax.of(uid);
  if (ts == null || ts.deflated || !ts.littleEndian) {
    throw DicomParseException(
        'transfer syntax ${uid.value} is not supported for reading yet '
        '(supported: Implicit and Explicit VR Little Endian, and their '
        'encapsulated forms)',
        offset: offset);
  }
  return ts;
}

/// What [_Parser.readElements] is reading, which decides where it stops.
enum _Scope {
  /// The file meta: stops at the first element outside group 0002.
  meta,

  /// A whole dataset: stops at its end, or before Pixel Data when
  /// [ReadOptions.stopBeforePixels] is set.
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
        pixelRepresentation = parent.pixelRepresentation;

  List<String> charset;
  int? bitsAllocated;
  int? pixelRepresentation;
}

final class _Parser {
  _Parser(this.bytes, this.ts, this.options)
      : data = ByteData.sublistView(bytes),
        endian = ts.littleEndian ? Endian.little : Endian.big;

  final Uint8List bytes;
  final ByteData data;
  final TransferSyntax ts;
  final Endian endian;
  final ReadOptions options;

  /// Reads elements from [start] until [end], or until [scope] says to stop,
  /// keeping [context] up to date. Returns them and the offset after the
  /// last.
  (List<DataElement>, int) readElements(
      int start, int end, _Scope scope, _Context context) {
    final elements = <DataElement>[];
    var at = start;
    while (at < end) {
      _need(at, 8, null);
      final tag = _tagAt(at);
      if (scope == _Scope.meta && tag >> 16 != 0x0002) break;
      if (tag == _itemDelimiter) {
        if (scope == _Scope.undefinedItem) return (elements, at + 8);
        throw DicomParseException('an Item Delimitation Item outside an item',
            offset: at);
      }
      if (scope == _Scope.dataset &&
          options.stopBeforePixels &&
          tag == _pixelData) {
        break;
      }

      final (:vr, :length, :valueStart) = _readHeader(at, tag, context);
      final (:valueEnd, :sequence) =
          _readValue(valueStart, length, vr, context, tag);
      final value = Uint8List.sublistView(bytes, valueStart, valueEnd);
      final element = readElement(
          Tag(tag),
          vr,
          RawValue(value,
              undefinedLength: length == _undefined,
              littleEndian: ts.littleEndian,
              specificCharacterSet: context.charset),
          decoded: sequence);
      elements.add(element);

      switch (tag) {
        case _specificCharacterSet:
          context.charset = element.value as List<String>;
        case _bitsAllocated when length >= 2:
          context.bitsAllocated = data.getUint16(valueStart, endian);
        case _pixelRepresentation when length >= 2:
          context.pixelRepresentation = data.getUint16(valueStart, endian);
      }
      at = valueEnd;
    }
    if (scope == _Scope.undefinedItem) {
      throw DicomParseException(
          'an undefined-length item has no Item Delimitation Item',
          offset: at);
    }
    return (elements, at);
  }

  /// Reads the header of the element at [at], whose tag is [tag]: its VR,
  /// its value length, and where its value starts.
  ({Vr vr, int length, int valueStart}) _readHeader(
      int at, int tag, _Context context) {
    if (ts.explicitVr) {
      final code = latin1.decode(Uint8List.sublistView(bytes, at + 4, at + 6));
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

  /// Finds where the value from [valueStart] ends. An SQ value's items are
  /// parsed on the way and returned as [Sequence]; other values are only
  /// sliced, and decode on first access.
  ({int valueEnd, Sequence? sequence}) _readValue(
      int valueStart, int length, Vr vr, _Context context, int tag) {
    if (length == _undefined) {
      if (vr == Vr.SQ) {
        final (items, after) = _readItems(valueStart, null, context, tag);
        return (valueEnd: after, sequence: Sequence(items));
      }
      return (valueEnd: _skipFragments(valueStart, tag), sequence: null);
    }
    _need(valueStart, length, tag);
    final valueEnd = valueStart + length;
    if (vr == Vr.SQ) {
      final (items, _) = _readItems(valueStart, valueEnd, context, tag);
      return (valueEnd: valueEnd, sequence: Sequence(items));
    }
    return (valueEnd: valueEnd, sequence: null);
  }

  /// Reads SQ items from [start] to [end], or to the Sequence Delimitation
  /// Item when [end] is null. Each item reads with a copy of [context].
  (List<Dataset>, int) _readItems(
      int start, int? end, _Context context, int sequenceTag) {
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
        final (elements, after) = readElements(
            at + 8, bytes.length, _Scope.undefinedItem, itemContext);
        items.add(readDataset(elements, ts.uid));
        at = after;
      } else {
        _need(at + 8, length, sequenceTag);
        final (elements, _) =
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

  int _u16(int at) => data.getUint16(at, endian);
  int _u32(int at) => data.getUint32(at, endian);
  int _tagAt(int at) => _u16(at) << 16 | _u16(at + 2);

  void _need(int at, int n, int? tag) {
    if (at + n > bytes.length) {
      throw DicomParseException('the data ends inside an element',
          offset: at, tag: tag == null ? null : Tag(tag));
    }
  }
}
