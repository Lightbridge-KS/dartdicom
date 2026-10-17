// Lenient reading (PRD C-10): each repair on bytes built to need it, what
// the dataset holds afterwards, and what writing it gives (F41).
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

import '../support/f41.dart';

const _explicit = '1.2.840.10008.1.2.1';
const _implicit = '1.2.840.10008.1.2';
const _sopClass = '1.2.840.10008.5.1.4.1.1.7';
const _sopInstance = '1.2.3.4';
const _undefined = 0xFFFFFFFF;
const _longVrs = {
  'OB', 'OD', 'OF', 'OL', 'OV', 'OW', 'SQ', 'SV', 'UC', 'UN', 'UR', 'UT', //
  'UV',
};

List<int> _u16(int v, {bool big = false}) =>
    big ? [v >> 8 & 0xFF, v & 0xFF] : [v & 0xFF, v >> 8 & 0xFF];
List<int> _u32(int v) =>
    [v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24 & 0xFF];
List<int> _tag(int t, {bool big = false}) =>
    [..._u16(t >> 16 & 0xFFFF, big: big), ..._u16(t & 0xFFFF, big: big)];

/// Text padded to even length: UIDs with NUL, the rest with a space.
List<int> _text(String s, {bool uid = false}) =>
    [...s.codeUnits, if (s.length.isOdd) uid ? 0 : 0x20];

/// An Explicit VR Little Endian element; [length] overrides the value's.
List<int> _ex(int tag, String vr, List<int> value, {int? length}) => [
      ..._tag(tag),
      ...vr.codeUnits,
      if (_longVrs.contains(vr)) ...[0, 0, ..._u32(length ?? value.length)],
      if (!_longVrs.contains(vr)) ..._u16(length ?? value.length),
      ...value,
    ];

/// An Implicit VR Little Endian element.
List<int> _im(int tag, List<int> value, {int? length}) =>
    [..._tag(tag), ..._u32(length ?? value.length), ...value];

List<int> _item(List<int> body) => [..._tag(0xFFFEE000), ..._u32(body.length)];

List<int> _undefinedItem(List<int> body) => [
      ..._tag(0xFFFEE000),
      ..._u32(_undefined),
      ...body,
      ..._tag(0xFFFEE00D),
      ..._u32(0),
    ];

List<int> get _sequenceEnd => [..._tag(0xFFFEE0DD), ..._u32(0)];

/// The SOP UIDs every written file needs, Explicit VR.
List<int> get _uids => [
      ..._ex(0x00080016, 'UI', _text(_sopClass, uid: true)),
      ..._ex(0x00080018, 'UI', _text(_sopInstance, uid: true)),
    ];

List<int> get _implicitUids => [
      ..._im(0x00080016, _text(_sopClass, uid: true)),
      ..._im(0x00080018, _text(_sopInstance, uid: true)),
    ];

/// File meta with the SOP UIDs and, unless null, transfer syntax [ts].
List<int> _meta({String? ts = _explicit}) {
  final body = [
    ..._ex(0x00020001, 'OB', [0, 1]),
    ..._ex(0x00020002, 'UI', _text(_sopClass, uid: true)),
    ..._ex(0x00020003, 'UI', _text(_sopInstance, uid: true)),
    if (ts != null) ..._ex(0x00020010, 'UI', _text(ts, uid: true)),
  ];
  return [..._ex(0x00020000, 'UL', _u32(body.length)), ...body];
}

/// A Part 10 file of [body] after the meta, or without the preamble and
/// `DICM`; [meta] false leaves the meta out too.
Uint8List _file(List<int> body,
        {String? ts = _explicit, bool preamble = true, bool meta = true}) =>
    Uint8List.fromList([
      if (preamble) ...List.filled(128, 0),
      if (preamble) ...'DICM'.codeUnits,
      if (meta) ..._meta(ts: ts),
      ...body,
    ]);

DicomFile _read(Uint8List bytes, {bool force = false}) =>
    DicomFile.fromBytes(bytes, options: ReadOptions(force: force));

List<RepairKind> _kinds(DicomFile file) =>
    [for (final r in file.report.repairs) r.kind];

/// F41's fixpoint for a repaired file ([expectFixpoint]). These cases
/// repair no content either, so the written file also reads clean.
DicomFile _expectFixpoint(DicomFile file) {
  final again = expectFixpoint(file);
  expect(again.report.isClean, isTrue, reason: '${again.report}');
  return again;
}

void main() {
  group('force (C-09)', () {
    final noPreamble = _file(_uids, preamble: false);

    test('data with no DICM prefix is refused, naming force', () {
      expect(
          () => _read(noPreamble),
          throwsA(isA<DicomParseException>()
              .having((e) => e.message, 'message', contains('force: true'))));
    });

    test('with force, the meta is read from offset 0 (noPreamble)', () {
      final file = _read(noPreamble, force: true);
      expect(_kinds(file), [RepairKind.noPreamble]);
      expect(file.meta.transferSyntaxUid?.value, _explicit);
      expect(file.dataset.get(DicomTags.sopInstanceUid), _sopInstance);
      expect(file.preamble, everyElement(0));
      _expectFixpoint(file);
    });

    test('with no meta either, a bare Implicit VR dataset (noFileMeta)', () {
      final file = _read(_file(_implicitUids, preamble: false, meta: false),
          force: true);
      expect(_kinds(file), [RepairKind.noPreamble, RepairKind.noFileMeta]);
      expect(file.dataset.transferSyntax?.value, _implicit);
      expect(file.dataset.get(DicomTags.sopClassUid), _sopClass);
      // Written in the syntax detected.
      final again = _expectFixpoint(file);
      expect(again.meta.transferSyntaxUid?.value, _implicit);
    });

    test('a bare Big Endian dataset is detected by its group numbers', () {
      final be = [
        ..._tag(0x00080016, big: true),
        ...'UI'.codeUnits,
        ..._u16(_text(_sopClass, uid: true).length, big: true),
        ..._text(_sopClass, uid: true),
      ];
      final file = _read(_file(be, preamble: false, meta: false), force: true);
      expect(file.dataset.transferSyntax, TransferSyntaxes.explicitVrBigEndian);
      expect(file.dataset.get(DicomTags.sopClassUid), _sopClass);
    });
  });

  group('the transfer syntax (C-10)', () {
    test('missing from the meta: detected from the data (syntaxDetected)', () {
      final file = _read(_file(_uids, ts: null));
      expect(_kinds(file), [RepairKind.syntaxDetected]);
      expect(file.dataset.transferSyntax?.value, _explicit);
      _expectFixpoint(file);
    });

    test('contradicted by the data: read as the data shows', () {
      final file = _read(_file([
        ..._implicitUids,
        ..._im(0x00100010, _text('Doe^Jane')),
      ]));
      expect(_kinds(file), [RepairKind.syntaxContradicted]);
      expect(file.dataset.get(DicomTags.patientName), 'Doe^Jane');
      _expectFixpoint(file);
    });

    test('an element with no VR in Explicit VR data is read as implicit', () {
      final file = _read(_file([
        ..._uids,
        ..._im(0x00100020, _text('ID-1')),
        ..._ex(0x00100030, 'DA', _text('20200101')),
      ]));
      expect(_kinds(file), [RepairKind.implicitElement]);
      expect(file.report.repairs.single.tag, DicomTags.patientId);
      expect(file.dataset.element(DicomTags.patientId)?.vr, Vr.LO);
      expect(file.dataset.get(DicomTags.patientId), 'ID-1');
      _expectFixpoint(file);
    });
  });

  group('UN and unknown VRs (C-10)', () {
    test('an unknown VR code is read as UN (unknownVr)', () {
      final file = _read(_file([
        ..._uids,
        ..._tag(0x00091001),
        ...'ZZ'.codeUnits,
        ..._u16(2),
        1,
        2,
      ]));
      expect(_kinds(file), [RepairKind.unknownVr]);
      expect(file.dataset.getBytes(const Tag(0x00091001)), [1, 2]);
      _expectFixpoint(file);
    });

    test('UN with a known VR takes the dictionary VR (unReplaced)', () {
      final file = _read(_file([
        ..._uids,
        ..._ex(0x00090010, 'UN', _text('ACME')),
        ..._ex(0x00100010, 'UN', _text('Doe^Jane')),
      ]));
      expect(_kinds(file), [RepairKind.unReplaced, RepairKind.unReplaced]);
      expect(file.dataset.element(const Tag(0x00090010))?.vr, Vr.LO);
      expect(file.dataset.element(DicomTags.patientName)?.vr, Vr.PN);
      expect(file.dataset.get(DicomTags.patientName), 'Doe^Jane');
      _expectFixpoint(file);
    });

    test('UN with an undefined length is a sequence (unSequence)', () {
      final file = _read(_file([
        ..._uids,
        ..._ex(0x00091010, 'UN', [], length: _undefined),
        ..._undefinedItem(_im(0x00100010, _text('Doe^Jane'))),
        ..._sequenceEnd,
      ]));
      expect(_kinds(file), [RepairKind.unSequence]);
      final items = file.dataset.getSequence(const Tag(0x00091010))!;
      expect(items.single.get(DicomTags.patientName), 'Doe^Jane');
      _expectFixpoint(file);
    });
  });

  group('values that break their VR (C-10, DA1)', () {
    test('a numeric length that does not fit keeps the whole values', () {
      final file = _read(_file([
        ..._uids,
        ..._ex(0x00280010, 'US', [1, 0, 9]),
      ]));
      expect(_kinds(file), [RepairKind.wrongLength]);
      expect(file.dataset.get(DicomTags.rows), 1);
      final again = _expectFixpoint(file);
      expect(again.dataset.get(DicomTags.rows), 1);
    });

    test('several values in a VM 1 element: reported, get gives the first', () {
      final file = _read(_file([
        ..._uids,
        ..._ex(0x00100010, 'PN', _text(r'Doe^Jane\Roe^Rita')),
        ..._ex(0x00280010, 'US', [1, 0, 2, 0]),
      ]));
      expect(
          _kinds(file), [RepairKind.multipleValues, RepairKind.multipleValues]);
      expect(file.dataset.get(DicomTags.patientName), 'Doe^Jane');
      expect(file.dataset.get(DicomTags.rows), 1);
      // Writing keeps the content, so the written file reports it too: it
      // isn't an encoding to repair.
      final again = DicomFile.fromBytes(file.toBytes());
      expect(_kinds(again), _kinds(file));
      expect(again.dataset.element(DicomTags.patientName)?.value,
          ['Doe^Jane', 'Roe^Rita']);
    });

    test('a group length that does not match is dropped on write', () {
      final file = _read(_file([
        ..._uids,
        ..._ex(0x00100000, 'UL', _u32(99)),
        ..._ex(0x00100010, 'PN', _text('Doe^Jane')),
      ]));
      expect(_kinds(file), [RepairKind.staleGroupLength]);
      expect(file.report.repairs.single.tag, const Tag(0x00100000));
      final again = _expectFixpoint(file);
      expect(again.dataset.element(const Tag(0x00100000)), isNull);
    });
  });

  group('data that ends early (C-10)', () {
    test('a short value at the end is kept short; the read is partial', () {
      final file = _read(_file([
        ..._uids,
        ..._ex(0x00100010, 'PN', _text('Doe^'), length: 10),
      ]));
      expect(_kinds(file), [RepairKind.truncated]);
      expect(file.dataset.element(DicomTags.patientName), isNotNull);
      expect(file.toBytes, throwsA(isA<DicomWriteException>()));
    });

    test('a header cut short ends the dataset', () {
      final file = _read(_file([
        ..._uids,
        ..._tag(0x7FE00010),
        ...'OB'.codeUnits,
        0,
        0,
      ]));
      expect(_kinds(file), [RepairKind.truncated]);
      expect(file.dataset.get(DicomTags.sopInstanceUid), _sopInstance);
      expect(file.toBytes, throwsA(isA<DicomWriteException>()));
    });

    test('an undefined-length value with no end is dropped', () {
      final file = _read(_file([
        ..._uids,
        ..._ex(0x7FE00010, 'OB', [], length: _undefined),
        ..._item([]),
        ..._tag(0xFFFEE000),
        ..._u32(4),
        1,
        2,
        3,
        4,
      ]));
      expect(_kinds(file), [RepairKind.valueDropped]);
      expect(file.dataset.element(DicomTags.pixelData), isNull);
      expect(file.dataset.get(DicomTags.sopInstanceUid), _sopInstance);
      expect(file.toBytes, throwsA(isA<DicomWriteException>()));
    });

    test('fewer bytes than a header after the last element are ignored', () {
      final file = _read(_file([..._uids, 1, 2, 3]));
      expect(_kinds(file), [RepairKind.trailingBytes]);
      _expectFixpoint(file);
    });
  });

  group('ambiguous VRs as pydicom resolves them', () {
    DicomFile implicitFile(List<int> body) =>
        _read(_file([..._implicitUids, ...body], ts: _implicit));

    test('implicit Pixel Data is OW', () {
      final file = implicitFile([
        ..._im(0x00280100, _u16(8)),
        ..._im(0x7FE00010, [1, 2, 3, 4]),
      ]);
      expect(file.report.isClean, isTrue);
      expect(file.dataset.element(DicomTags.pixelData)?.vr, Vr.OW);
    });

    test('US or SS follows Pixel Representation', () {
      final signed = implicitFile([
        ..._im(0x00280103, _u16(1)),
        ..._im(0x00280106, [0xFF, 0xFF]),
      ]);
      expect(
          signed.dataset.element(DicomTags.smallestImagePixelValue)?.vr, Vr.SS);
      expect(signed.dataset.get(DicomTags.smallestImagePixelValue), -1);
      final unsigned = implicitFile([
        ..._im(0x00280106, [0xFF, 0xFF])
      ]);
      expect(unsigned.dataset.get(DicomTags.smallestImagePixelValue), 65535);
    });

    test('an item inherits Pixel Representation from around it', () {
      final file = implicitFile([
        ..._im(0x00081140, [], length: _undefined),
        ..._undefinedItem(_im(0x00280106, [0xFF, 0xFF])),
        ..._sequenceEnd,
        ..._im(0x00280103, _u16(1)),
      ]);
      final item =
          file.dataset.require(DicomTags.referencedImageSequence).first;
      expect(item.get(DicomTags.smallestImagePixelValue), -1);
    });

    test('LUT Data is US when the descriptor says one entry, else OW', () {
      Vr lutDataVr(int entries) {
        final item = [
          ..._im(0x00283002, [..._u16(entries), ..._u16(0), ..._u16(16)]),
          ..._im(0x00283006, [1, 0]),
        ];
        final file = implicitFile([
          ..._im(0x00283010, [], length: _undefined),
          ..._undefinedItem(item),
          ..._sequenceEnd,
        ]);
        return file.dataset
            .require(DicomTags.voilutSequence)
            .first
            .element(DicomTags.lutData)!
            .vr;
      }

      expect(lutDataVr(1), Vr.US);
      expect(lutDataVr(256), Vr.OW);
    });

    test('Overlay Data is OW', () {
      final file = implicitFile([
        ..._im(0x60003000, [0, 0])
      ]);
      expect(file.dataset.element(const Tag(0x60003000))?.vr, Vr.OW);
    });
  });

  group('tags (C-09)', () {
    test('reads only the tags asked for, and (0008,0005); partial', () {
      final bytes = _file([
        ..._ex(0x00080005, 'CS', _text('ISO_IR 192')),
        ..._uids,
        ..._ex(0x00100010, 'PN', _text('Doe^Jane')),
        ..._ex(0x00100020, 'LO', _text('ID-1')),
      ]);
      final file = DicomFile.fromBytes(bytes,
          options: ReadOptions(tags: {DicomTags.patientName}));
      expect([for (final e in file.dataset.elements) e.tag],
          [DicomTags.specificCharacterSet, DicomTags.patientName]);
      expect(file.report.isClean, isTrue);
      expect(file.toBytes, throwsA(isA<DicomWriteException>()));
    });
  });

  test('sequences nested past the limit are malformed, not a stack overflow',
      () {
    List<int> nested(int depth) => depth == 0
        ? []
        : [
            ..._im(0x0040A730, [], length: _undefined),
            ..._undefinedItem(nested(depth - 1)),
            ..._sequenceEnd,
          ];
    Uint8List file(int depth) =>
        _file([..._implicitUids, ...nested(depth)], ts: _implicit);

    expect(_read(file(10)).report.isClean, isTrue);
    expect(() => _read(file(70)), throwsA(isA<DicomParseException>()));
  });

  test('the report names tags and offsets, never values (I-9)', () {
    final file = _read(_file([
      ..._uids,
      ..._ex(0x00100010, 'UN', _text('SECRET^NAME')),
      ..._ex(0x00100020, 'LO', _text('SECRET-ID'), length: 40),
    ]));
    expect(file.report.repairs, hasLength(2));
    final texts = [
      file.report.toString(),
      file.report.summary(),
      for (final r in file.report.repairs) r.toString(),
    ];
    expect(texts, everyElement(isNot(contains('SECRET'))));
    expect(file.report.summary(), '2 repairs: unReplaced ×1, truncated ×1');
  });
}
