// The PHI canary (I-9, M2 step 7): the phi_canary fixture carries a marker
// (ZXQV) in names, IDs, descriptions, a private element and nested sequence
// text. Element values must never reach a toString, an exception or a read
// report, so the marker must appear nowhere but in the values themselves.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/io.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

final _marker = RegExp('zxqv', caseSensitive: false);
const _privateText = Tag(0x00091001);

/// Fails with [what] if [text] carries the marker.
void _clean(String text, String what) {
  if (_marker.hasMatch(text)) fail('$what shows a value: $text');
}

/// Runs [action]; an exception it throws must not carry the marker.
void _quiet(void Function() action, String what) {
  try {
    action();
  } on Object catch (e) {
    _clean('$e', '$what (${e.runtimeType})');
    if (e is! DicomException && e is! ArgumentError) {
      fail('$what threw ${e.runtimeType}, not a DicomException');
    }
  }
}

/// Reads [bytes] (with force), touches every value and the report, and
/// writes; nothing on the way may show a value.
void _readAll(Uint8List bytes, String what) {
  _quiet(() {
    final file =
        DicomFile.fromBytes(bytes, options: const ReadOptions(force: true));
    _strings(file).forEach((s) => _clean(s, what));
    file.toBytes(options: const WriteOptions(deflateCodec: ZLibDeflateCodec()));
  }, what);
}

/// Every string a file's objects give about themselves, values touched.
Iterable<String> _strings(DicomFile file) sync* {
  yield '$file';
  yield '${file.meta}';
  yield '${file.report}';
  yield file.report.summary();
  for (final r in file.report.repairs) {
    yield '$r';
  }
  Iterable<String> dataset(Dataset ds) sync* {
    yield '$ds';
    for (final e in ds.elements) {
      yield '$e';
      final value = e.value;
      if (value is Sequence) {
        yield '$value';
        for (final item in value) {
          yield* dataset(item);
        }
      }
    }
  }

  yield* dataset(file.meta.dataset);
  yield* dataset(file.dataset);
}

void main() {
  final bytes = fixture('synthetic/phi_canary.dcm').readAsBytesSync();
  final file = DicomFile.fromBytes(bytes);
  final ds = file.dataset;

  test('the canary carries the marker in its values', () {
    expect(ds.get(DicomTags.patientName), contains('ZXQV'));
    expect(ds.getStrings(_privateText).single, contains('ZXQV'));
    final nested = ds
        .require(DicomTags.referencedImageSequence)
        .single
        .require(DicomTags.purposeOfReferenceCodeSequence)
        .single;
    expect(nested.get(DicomTags.codeMeaning), contains('ZXQV'));
  });

  test('no toString shows a value', () {
    _strings(file).forEach((s) => _clean(s, 'toString'));
    final block = ds.privateBlock(0x0009, 'DARTDICOM CANARY')!;
    _clean('$block', 'PrivateBlock');
  });

  test('no exception from a truncated or damaged read shows a value', () {
    for (var at = 0; at < bytes.length; at += 3) {
      _readAll(Uint8List.sublistView(bytes, 0, at), 'truncated at $at');
    }
    // Damage inside every value that carries the marker, and before it.
    final text = latin1.decode(bytes);
    for (final m in RegExp('ZXQV').allMatches(text)) {
      for (final offset in [-8, -6, -4, -2, 0, 2]) {
        final at = m.start + offset;
        final damaged = Uint8List.fromList(bytes)..[at] ^= 0xFF;
        _readAll(damaged, 'damaged at $at');
      }
    }
  });

  test('no wrong-type read shows a value', () {
    _quiet(() => ds.getInts(_privateText), 'getInts on text');
    _quiet(() => ds.getBytes(_privateText), 'getBytes on text');
    _quiet(() => ds.getSequence(_privateText), 'getSequence on text');
    _quiet(
        () => ds.getStrings(DicomTags.patientName), 'untyped on a typed tag');
    _quiet(() => ds.require(DicomTags.patientAge), 'require of an absent tag');
    _quiet(() => ds.setRaw(_privateText, Vr.US, ['ZXQV']), 'setRaw mistyped');
    // A DS whose text isn't a number decodes to an error.
    _quiet(() => _dsElement('ZXQV1.5').value, 'a DS that is not a number');
  });

  test('no write failure shows a value', () {
    // Text the character set can't encode (F35).
    final unencodable = DicomFile.fromBytes(bytes);
    unencodable.dataset
      ..remove(DicomTags.specificCharacterSet)
      ..set(DicomTags.patientName, 'ZXQV^Ünencodable');
    _quiet(unencodable.toBytes, 'unencodable text');
    // A value too long for its length field.
    final long = Dataset()..set(DicomTags.studyDescription, 'ZXQV' * 20000);
    _quiet(
        () => long.toBytes(
            transferSyntax: TransferSyntaxes.explicitVrLittleEndian),
        'an over-long value');
    // Contradicting SOP UIDs (I-17).
    final contradicting = DicomFile.fromBytes(bytes);
    contradicting.dataset.set(DicomTags.sopInstanceUid, '1.2.3.4');
    _quiet(contradicting.toBytes, 'contradicting SOP UIDs');
  });

  test('no read report shows a value', () {
    // The name and the private text as UN, each with a VR the reader knows
    // (unReplaced, private creator LO included), then a value cut short.
    List<int> un(int tag, String text) {
      final value = utf8.encode(text.length.isOdd ? '$text ' : text);
      return [
        tag >> 16 & 0xFF, tag >> 24, tag & 0xFF, tag >> 8 & 0xFF, //
        ...'UN'.codeUnits, 0, 0,
        value.length & 0xFF, value.length >> 8, 0, 0,
        ...value,
      ];
    }

    final repaired = Dataset.fromBytes(
        Uint8List.fromList([
          ...un(0x00090010, 'ZXQV CREATOR'),
          ...un(0x00100010, 'ZXQVFamily^ZXQVGiven'),
          ...un(0x00100020, 'ZXQV-ID-0001'),
        ]),
        transferSyntax: TransferSyntaxes.explicitVrLittleEndian);
    expect(repaired.report.repairs.map((r) => r.kind),
        List.filled(3, RepairKind.unReplaced));
    for (final s in [
      '${repaired.report}',
      repaired.report.summary(),
      for (final r in repaired.report.repairs) '$r',
    ]) {
      _clean(s, 'unReplaced report');
    }
    final name = latin1.decode(bytes).indexOf('ZXQVFamily');
    final cut = DicomFile.fromBytes(Uint8List.sublistView(bytes, 0, name + 6));
    expect(cut.report.repairs.map((r) => r.kind), [RepairKind.truncated]);
    _strings(cut).forEach((s) => _clean(s, 'truncated report'));
  });
}

/// A DS element read from Explicit VR bytes holding [text].
DataElement _dsElement(String text) {
  final value = utf8.encode(text.length.isOdd ? '$text ' : text);
  final ds = Dataset.fromBytes(
      Uint8List.fromList([
        0x18, 0x00, 0x50, 0x00, // (0018,0050) Slice Thickness, DS
        ...'DS'.codeUnits,
        value.length, 0,
        ...value,
      ]),
      transferSyntax: TransferSyntaxes.explicitVrLittleEndian);
  return ds.element(DicomTags.sliceThickness)!;
}
