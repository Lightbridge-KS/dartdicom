// Byte sources (blueprint §5, F40): views, prefixes and NeedMoreBytes.
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom/src/source/byte_source.dart' show PrefixSource;
import 'package:test/test.dart';

void main() {
  final bytes = Uint8List.fromList(List.generate(100, (i) => i));

  test('BytesSource reads views and cannot defer', () {
    final source = BytesSource(bytes);
    final copy = Uint8List.fromList(bytes);
    final view = BytesSource(copy).read(10, 5);
    expect(view, [10, 11, 12, 13, 14]);
    copy[10] = 99; // a view sees writes to the bytes it views
    expect(view[0], 99);
    expect(source.opener, isNull);
  });

  test('PrefixSource reads copies within its prefix', () {
    final source = PrefixSource(Uint8List.sublistView(bytes, 0, 50), 100);
    final copy = source.read(10, 5);
    copy[0] = 99;
    expect(bytes[10], 10);
    expect(source.length, 100);
  });

  test('PrefixSource asks for more past its prefix', () {
    final source = PrefixSource(Uint8List.sublistView(bytes, 0, 50), 100);
    expect(() => source.read(48, 4),
        throwsA(isA<NeedMoreBytes>().having((e) => e.end, 'end', 52)));
  });

  test('a parse over a too-short prefix asks for more, never fails', () {
    final ds = Dataset()..set(DicomTags.patientId, 'P');
    final encoded =
        ds.toBytes(transferSyntax: TransferSyntaxes.explicitVrLittleEndian);
    final file = Uint8List.fromList([
      ...FileMetaInformation.forInstance(
              sopClassUid: SopClasses.ctImageStorage,
              sopInstanceUid: const Uid('1.2.3'),
              transferSyntax: TransferSyntaxes.explicitVrLittleEndian)
          .toHeaderBytes(),
      ...encoded,
    ]);
    final short =
        PrefixSource(Uint8List.sublistView(file, 0, 140), file.length);
    expect(() => DicomFile.fromSource(short), throwsA(isA<NeedMoreBytes>()));
    final whole = PrefixSource(file, file.length);
    expect(DicomFile.fromSource(whole).dataset.get(DicomTags.patientId), 'P');
  });
}
