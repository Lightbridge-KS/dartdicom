// Transfer syntax descriptors and the implementation identity.
import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

void main() {
  test('native transfer syntaxes describe their encoding', () {
    final implicit =
        TransferSyntax.of(TransferSyntaxes.implicitVrLittleEndian)!;
    expect((implicit.explicitVr, implicit.littleEndian), (false, true));
    final be = TransferSyntax.of(TransferSyntaxes.explicitVrBigEndian)!;
    expect((be.explicitVr, be.littleEndian), (true, false));
    expect(
        TransferSyntax.of(TransferSyntaxes.deflatedExplicitVrLittleEndian)!
            .deflated,
        isTrue);
  });

  test('any other registered transfer syntax is encapsulated', () {
    final jpeg = TransferSyntax.of(TransferSyntaxes.jpegBaseline8Bit)!;
    expect((jpeg.explicitVr, jpeg.littleEndian, jpeg.encapsulated),
        (true, true, true));
    expect(TransferSyntax.of(const Uid('1.2.3.4')), isNull);
  });

  test('the implementation UID is a valid UID and the name fits SH', () {
    expect(dartdicomImplementationClassUid.value,
        matches(RegExp(r'^2\.25\.[1-9][0-9]*$')));
    expect(dartdicomImplementationClassUid.value.length, lessThanOrEqualTo(64));
    expect(dartdicomImplementationVersionName.length, lessThanOrEqualTo(16));
  });
}
