import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../dataset/dataset.dart';
import '../dataset/read_report.dart';
import '../errors.dart';
import '../source/byte_source.dart';
import '../tag/tags.g.dart';
import '../uid/transfer_syntax.dart';
import '../uid/uid.dart';
import 'inflate.dart';
import 'parse/header.dart' show detectSyntax;
import 'parse/walker.dart';
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
//
// This file frames a Part 10 file or a bare dataset and picks its transfer
// syntax (noPreamble, noFileMeta, syntaxDetected). The walk lives in parse/,
// and nothing else in lib/ imports parse/ (I-31):
//
//   walker.dart         elements, values and items, recursively; when to stop
//   header.dart         what an element's header says: VR, length, explicit
//   checks.dart         the repairs that are only reported
//   ambiguity.dart      ambiguous VRs, settled once the walk is done
//   level.dart          one dataset level's state
//   source_reader.dart  the bytes, in the syntax's byte order

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
      Walker(source, TransferSyntax.explicitVrLittleEndian, options, repairs)
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
    ts = detectSyntax(source, bodyStart);
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
      Walker(source, ts, options, found).readTop(start);
  return readDataset(elements, ts.uid,
      partial: partial, report: ReadReport(found));
}
