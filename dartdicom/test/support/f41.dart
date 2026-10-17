// I-10 under blueprint F41, shared by the fixture, corpus and lenient-read
// tests. Platform-free, so web tests can use it: a caller that writes
// Deflated passes the codec to compress with.
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

/// Inflates both sides when Deflated bytes are compared. Inflating is exact,
/// so any codec gives the same body.
const _inflate = PureDartInflate();

/// Repairs that describe the content rather than its encoding, so writing
/// keeps them: the written file still reports them.
const contentRepairs = {RepairKind.multipleValues};

/// Whether [file]'s meta and dataset contradict each other on the SOP
/// Instance UID, so that writing it is refused (I-17).
bool contradictsSopUids(DicomFile file) {
  final metaUid = file.meta.mediaStorageSopInstanceUid?.value;
  final datasetUid = file.dataset.get(DicomTags.sopInstanceUid);
  return metaUid != null && datasetUid != null && metaUid != datasetUid;
}

/// Checks [file], read from [bytes], against F41's rule; returns why it
/// failed, or null.
///
/// - A partial read: writing it is refused.
/// - Big Endian, or contradicting SOP UIDs: writing as read is refused, so
///   I-10 doesn't apply (the fixture round trip checks both refusals).
/// - No SOP Class or Instance UID in the meta or the dataset: there is no
///   meta to derive (data §5), so writing it is refused.
/// - A clean read: written back byte for byte (Deflated: the same header
///   and inflated body).
/// - A repaired read: a fixpoint. The written file re-reads with no repair
///   of the encoding, to the same elements (less the stale group lengths
///   dropped), and writing that again gives the same bytes.
///
/// Writing Deflated needs [deflateCodec] (zlib, on native platforms).
String? checkF41(DicomFile file, Uint8List bytes,
    {DeflateCodec? deflateCodec}) {
  final options = WriteOptions(deflateCodec: deflateCodec);
  if (file.dataset.report.repairs.any((r) =>
      r.kind == RepairKind.truncated || r.kind == RepairKind.valueDropped)) {
    try {
      file.toBytes(options: options);
      return 'F41: a partial read was written';
    } on DicomWriteException {
      return null;
    }
  }
  if (file.meta.transferSyntaxUid == TransferSyntaxes.explicitVrBigEndian) {
    return null;
  }
  if (contradictsSopUids(file)) return null;
  bool lacks(One<String> metaTag, One<String> datasetTag) =>
      file.meta.dataset.get(metaTag) == null &&
      file.dataset.get(datasetTag) == null;
  if (lacks(DicomTags.mediaStorageSopClassUid, DicomTags.sopClassUid) ||
      lacks(DicomTags.mediaStorageSopInstanceUid, DicomTags.sopInstanceUid)) {
    try {
      file.toBytes(options: options);
      return 'F41: a file with no SOP UIDs was written';
    } on DicomWriteException {
      return null;
    }
  }
  final Uint8List written;
  try {
    written = file.toBytes(options: options);
  } on DicomWriteException catch (e) {
    return 'I-10 write: ${e.message}';
  }
  if (file.report.isClean) return sameBytes(file, written, bytes);
  return _fixpoint(file, written, options).problem;
}

/// Expects [file], a repaired read, to reach F41's fixpoint, and returns
/// the written file read back, for further checks.
DicomFile expectFixpoint(DicomFile file, {DeflateCodec? deflateCodec}) {
  final options = WriteOptions(deflateCodec: deflateCodec);
  final (:reread, :problem) =
      _fixpoint(file, file.toBytes(options: options), options);
  expect(problem, isNull);
  return reread!;
}

/// F41 for a repaired [file] that was [written]: the written file re-reads
/// with no repair of the encoding, to the same elements (less the stale
/// group lengths dropped), and writing that again gives the same bytes.
/// Returns the re-read file, and why it failed.
({DicomFile? reread, String? problem}) _fixpoint(
    DicomFile file, Uint8List written, WriteOptions options) {
  final DicomFile reread;
  try {
    reread = DicomFile.fromBytes(written);
  } on DicomParseException catch (e) {
    return (
      reread: null,
      problem: 'F41: the written file does not read: ${e.message}'
    );
  }
  final left =
      reread.report.repairs.where((r) => !contentRepairs.contains(r.kind));
  if (left.isNotEmpty) {
    return (reread: reread, problem: 'F41: the written file reads with $left');
  }
  final stale = {
    for (final r in file.report.repairs)
      if (r.kind == RepairKind.staleGroupLength) r.tag!,
  };
  final before = flatten(file.dataset, skip: stale);
  final after = flatten(reread.dataset);
  final matcher = equals(before);
  final state = <Object?, Object?>{};
  if (!matcher.matches(after, state)) {
    final why =
        matcher.describeMismatch(after, StringDescription(), state, false);
    return (
      reread: reread,
      problem: 'F41: the written file reads differently: $why'
    );
  }
  final again = reread.toBytes(options: options);
  final same = sameBytes(reread, again, written);
  return (
    reread: reread,
    problem: same == null ? null : 'F41: not a fixpoint: $same'
  );
}

/// I-10's comparison: identical bytes, or for Deflated, an identical header
/// and inflated body (F41). Returns the difference, or null.
String? sameBytes(DicomFile file, Uint8List written, Uint8List read) {
  if (file.meta.transferSyntaxUid ==
      TransferSyntaxes.deflatedExplicitVrLittleEndian) {
    final int groupLength =
        file.meta.dataset.require(DicomTags.fileMetaInformationGroupLength);
    final metaEnd = 144 + groupLength;
    return _firstDifference(
            written.sublist(0, metaEnd), read.sublist(0, metaEnd)) ??
        _firstDifference(
            _inflate.inflate(Uint8List.sublistView(written, metaEnd)),
            _inflate.inflate(Uint8List.sublistView(read, metaEnd)));
  }
  return _firstDifference(written, read);
}

String? _firstDifference(Uint8List written, Uint8List read) {
  if (written.length != read.length) {
    return 'I-10: ${written.length} bytes written, ${read.length} read';
  }
  for (var i = 0; i < read.length; i++) {
    if (written[i] != read[i]) return 'I-10: first difference at byte $i';
  }
  return null;
}

/// Every element, recursively, as [tag, VR, value] for comparison; [skip]
/// leaves top-level tags out.
List<Object> flatten(Dataset ds, {Set<Tag> skip = const {}}) => [
      for (final e in ds.elements.where((e) => !skip.contains(e.tag)))
        [
          e.tag.value,
          e.vr.code,
          switch (e.value) {
            final Sequence s => [for (final item in s) flatten(item)],
            final Object v => v,
          },
        ],
    ];
