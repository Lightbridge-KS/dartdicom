import 'dart:convert';

import '../../dataset/read_report.dart';
import '../../dictionary/dictionary.dart';
import '../../source/byte_source.dart';
import '../../tag/tag.dart';
import '../../uid/transfer_syntax.dart';
import '../../vr/vr.dart';
import 'source_reader.dart';

// Element headers: what the bytes at an element say it is. The repairs
// found here are about a header (syntaxContradicted, implicitElement,
// unknownVr, unSequence, unReplaced).

const _undefined = 0xFFFFFFFF;

/// An element header: its VR, value length and where the value starts; the
/// ambiguous dictionary VRs still to settle, and whether its SQ items are
/// implicit.
final class ElementHeader {
  ElementHeader(this.vr, this.length, this.valueStart,
      {this.ambiguous, this.itemsImplicit = false});

  final Vr vr;
  final int length;
  final int valueStart;
  final List<Vr>? ambiguous;
  final bool itemsImplicit;

  bool get undefinedLength => length == _undefined;
}

/// Reads element headers, and decides each element's VR: from the bytes in
/// Explicit VR, from the dictionary in Implicit VR, and repaired where the
/// two disagree with the data.
final class HeaderReader {
  HeaderReader(this.reader, this.repairs);

  final SourceReader reader;
  final List<Repair> repairs;

  ByteSource get source => reader.source;

  /// Reads the header of the element at [at], whose tag is [tag], in a
  /// level read as [explicit] VR.
  ElementHeader read(int at, int tag, {required bool explicit}) {
    if (!explicit) return _implicit(at, tag);
    reader.need(at, 8, tag);
    final code = source.read(at + 4, 2);
    if (!_isLetter(code[0]) || !_isLetter(code[1])) {
      // No VR where Explicit VR data has one: read this element as
      // implicit (pydicom does the same, silently).
      repairs
          .add(Repair(RepairKind.implicitElement, tag: Tag(tag), offset: at));
      return _implicit(at, tag);
    }
    var vr = Vr.fromCode(latin1.decode(code));
    final int length;
    final int valueStart;
    if (vr == null) {
      repairs.add(Repair(RepairKind.unknownVr, tag: Tag(tag), offset: at));
      vr = Vr.UN;
      length = reader.u16(at + 6);
      valueStart = at + 8;
    } else if (vr.hasLongLength) {
      reader.need(at, 12, tag);
      length = reader.u32(at + 8);
      valueStart = at + 12;
    } else {
      length = reader.u16(at + 6);
      valueStart = at + 8;
    }
    if (vr == Vr.UN) return _unknownValue(at, tag, length, valueStart);
    return ElementHeader(vr, length, valueStart);
  }

  /// Whether the data at [at] reads as Explicit VR: two letters where the
  /// VR would be. If that contradicts [expected], the data wins and the
  /// contradiction is reported (pydicom checks at the dataset start and at
  /// each item).
  bool explicitAt(int at, bool expected, int? sequenceTag) {
    if (at + 8 > source.length) return expected;
    final tag = reader.tagAt(at);
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

  ElementHeader _implicit(int at, int tag) {
    final length = reader.u32(at + 4);
    final (vr, ambiguous) = _dictionaryVr(Tag(tag));
    // A tag the dictionary doesn't know, with an undefined length, can only
    // be a sequence (PS3.5 §7.5.1); its items are Implicit VR too.
    if (vr == Vr.UN && length == _undefined) {
      return ElementHeader(Vr.SQ, length, at + 8, itemsImplicit: true);
    }
    return ElementHeader(vr, length, at + 8, ambiguous: ambiguous);
  }

  /// An explicit UN: given the dictionary's VR if it knows one (pydicom's
  /// `replace_un_with_known_vr`), or read as an SQ of Implicit VR items if
  /// its length is undefined (PS3.5 §6.2.2).
  ElementHeader _unknownValue(int at, int tag, int length, int valueStart) {
    final t = Tag(tag);
    if (length == _undefined) {
      repairs.add(Repair(RepairKind.unSequence, tag: t, offset: at));
      return ElementHeader(Vr.SQ, length, valueStart, itemsImplicit: true);
    }
    final (vr, ambiguous) = _dictionaryVr(t);
    final known =
        vr != Vr.UN && length < 0xFFFF && (!t.isPrivate || vr == Vr.LO);
    if (!known) return ElementHeader(Vr.UN, length, valueStart);
    repairs.add(Repair(RepairKind.unReplaced, tag: t, offset: at));
    // A UN value is in Implicit VR terms, an SQ's items included.
    return ElementHeader(vr, length, valueStart,
        ambiguous: ambiguous, itemsImplicit: vr == Vr.SQ);
  }
}

/// pydicom's detection, when no syntax is declared: two letters at offset 4
/// mean Explicit VR; a little-endian group of 1024 or more means the data
/// is Big Endian.
TransferSyntax detectSyntax(ByteSource source, int at) {
  if (at + 8 > source.length) return TransferSyntax.implicitVrLittleEndian;
  final b = source.read(at, 8);
  final group = b[0] | b[1] << 8;
  final explicit = _isLetter(b[4]) && _isLetter(b[5]);
  if (group >= 1024 && explicit) return TransferSyntax.explicitVrBigEndian;
  return explicit
      ? TransferSyntax.explicitVrLittleEndian
      : TransferSyntax.implicitVrLittleEndian;
}

/// The VR the dictionary gives [tag] (LO for a private creator, UL for a
/// group length, UN for an unknown tag), and its VRs when it gives several,
/// to settle once the level is read.
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

bool _isLetter(int b) => b >= 0x41 && b <= 0x5A;
