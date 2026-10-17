import 'dart:convert';
import 'dart:typed_data';

import '../dataset/dataset.dart';
import '../dataset/element.dart';
import '../dataset/sequence.dart';
import '../dictionary/dictionary.dart';
import '../errors.dart';
import '../tag/tag.dart';
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
  final (metaElements, bodyStart) = metaParser.readElements(132, bytes.length,
      groupOnly: 0x0002, charset: const [], context: _Context());
  final meta =
      readDataset(metaElements, TransferSyntax.explicitVrLittleEndian.uid);
  final tsUid = meta.elements
      .where((e) => e.tag.value == 0x00020010)
      .map((e) => (e.value as List<String>).firstOrNull)
      .firstOrNull;
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
  final (elements, _) = _Parser(bytes, ts, options).readElements(
      start, bytes.length,
      charset: const [], context: _Context(), topLevel: true);
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

/// What implicit VR resolution needs from elements read earlier.
final class _Context {
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

  int _u16(int at) => data.getUint16(at, endian);
  int _u32(int at) => data.getUint32(at, endian);
  int _tagAt(int at) => _u16(at) << 16 | _u16(at + 2);

  void _need(int at, int n, int? tag) {
    if (at + n > bytes.length) {
      throw DicomParseException('the data ends inside an element',
          offset: at, tag: tag == null ? null : Tag(tag));
    }
  }

  /// Reads elements from [start] until [end], an Item Delimitation Item
  /// (for an undefined-length item), or, with [groupOnly], the first
  /// element of another group. Returns them and the offset after the last.
  (List<DataElement>, int) readElements(
    int start,
    int end, {
    required List<String> charset,
    required _Context context,
    int? groupOnly,
    bool topLevel = false,
    bool untilItemDelimiter = false,
  }) {
    final elements = <DataElement>[];
    var at = start;
    while (at < end) {
      _need(at, 8, null);
      final tag = _tagAt(at);
      if (groupOnly != null && tag >> 16 != groupOnly) break;
      if (tag == _itemDelimiter) {
        if (untilItemDelimiter) return (elements, at + 8);
        throw DicomParseException('an Item Delimitation Item outside an item',
            offset: at);
      }
      if (topLevel && options.stopBeforePixels && tag == _pixelData) break;

      final Vr vr;
      final int length;
      final int valueStart;
      if (ts.explicitVr) {
        final code =
            latin1.decode(Uint8List.sublistView(bytes, at + 4, at + 6));
        final explicit = Vr.fromCode(code);
        if (explicit == null) {
          throw DicomParseException('unknown VR code in an explicit VR element',
              offset: at + 4, tag: Tag(tag));
        }
        vr = explicit;
        if (vr.hasLongLength) {
          _need(at, 12, tag);
          length = _u32(at + 8);
          valueStart = at + 12;
        } else {
          length = _u16(at + 6);
          valueStart = at + 8;
        }
      } else {
        length = _u32(at + 4);
        valueStart = at + 8;
        final known = _implicitVr(Tag(tag), context);
        // A tag the dictionary doesn't know, with an undefined length, can
        // only be a sequence (PS3.5 §7.5.1).
        vr = known == Vr.UN && length == _undefined ? Vr.SQ : known;
      }

      final int valueEnd;
      final int next;
      Object? decoded;
      if (length == _undefined) {
        if (vr == Vr.SQ) {
          final (items, after) =
              _readItems(valueStart, null, charset, context, tag);
          decoded = Sequence(items);
          valueEnd = next = after;
        } else {
          valueEnd = next = _skipFragments(valueStart, tag);
        }
      } else {
        _need(valueStart, length, tag);
        valueEnd = next = valueStart + length;
        if (vr == Vr.SQ) {
          final (items, _) =
              _readItems(valueStart, valueEnd, charset, context, tag);
          decoded = Sequence(items);
        }
      }

      final value = Uint8List.sublistView(bytes, valueStart, valueEnd);
      final element = readElement(
          Tag(tag),
          vr,
          RawValue(value,
              undefinedLength: length == _undefined,
              littleEndian: ts.littleEndian,
              specificCharacterSet: charset),
          decoded: decoded);
      elements.add(element);

      switch (tag) {
        case _specificCharacterSet:
          charset = element.value as List<String>;
        case _bitsAllocated when length >= 2:
          context.bitsAllocated = data.getUint16(valueStart, endian);
        case _pixelRepresentation when length >= 2:
          context.pixelRepresentation = data.getUint16(valueStart, endian);
      }
      at = next;
    }
    if (untilItemDelimiter) {
      throw DicomParseException(
          'an undefined-length item has no Item Delimitation Item',
          offset: at);
    }
    return (elements, at);
  }

  /// Reads SQ items from [start] to [end], or to the Sequence Delimitation
  /// Item when [end] is null. Items inherit the sequence's character set.
  (List<Dataset>, int) _readItems(int start, int? end, List<String> charset,
      _Context context, int sequenceTag) {
    final items = <Dataset>[];
    var at = start;
    while (end == null || at < end) {
      _need(at, 8, sequenceTag);
      final tag = _tagAt(at);
      final length = _u32(at + 4);
      if (tag == _sequenceDelimiter && end == null) return (items, at + 8);
      if (tag != _item) {
        throw DicomParseException('expected an Item in a sequence',
            offset: at, tag: Tag(sequenceTag));
      }
      final itemContext = _Context()
        ..bitsAllocated = context.bitsAllocated
        ..pixelRepresentation = context.pixelRepresentation;
      if (length == _undefined) {
        final (elements, after) = readElements(at + 8, bytes.length,
            charset: charset, context: itemContext, untilItemDelimiter: true);
        items.add(readDataset(elements, ts.uid));
        at = after;
      } else {
        _need(at + 8, length, sequenceTag);
        final (elements, _) = readElements(at + 8, at + 8 + length,
            charset: charset, context: itemContext);
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
      _need(at, 8, tag);
      final itemTag = _tagAt(at);
      final length = _u32(at + 4);
      if (itemTag == _sequenceDelimiter) return at + 8;
      if (itemTag != _item || length == _undefined) {
        throw DicomParseException('malformed encapsulated value',
            offset: at, tag: Tag(tag));
      }
      _need(at + 8, length, tag);
      at += 8 + length;
    }
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
}
