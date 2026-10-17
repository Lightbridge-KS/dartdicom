// Platform-neutral: runs on the VM and compiled to JS (`dart test -p chrome`).
import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

void main() {
  test('Tag.of packs group and element into one int', () {
    const tag = Tag.of(0x0010, 0x0010);
    expect(tag, Tag(0x00100010));
    expect(tag.group, 0x0010);
    expect(tag.element, 0x0010);
  });

  test('high-group tags stay positive and exact on every platform', () {
    // (FFFE,E0DD) Sequence Delimitation Item: the top bit is set, which
    // dart2js bitwise operators must not turn negative.
    const tag = Tag.of(0xFFFE, 0xE0DD);
    expect(tag.value, 0xFFFEE0DD);
    expect(tag.group, 0xFFFE);
    expect(tag.element, 0xE0DD);
  });

  test('isPrivate follows PS3.5 §7.8.1', () {
    expect(const Tag.of(0x0009, 0x0010).isPrivate, isTrue);
    expect(const Tag.of(0x0010, 0x0010).isPrivate, isFalse);
    for (final group in [0x0001, 0x0003, 0x0005, 0x0007, 0xFFFF]) {
      expect(Tag.of(group, 0x0000).isPrivate, isFalse, reason: 'group $group');
    }
  });

  test('a Tag is its int at runtime (zero cost)', () {
    const Object tag = Tag(0x00080018);
    expect(tag, isA<int>());
  });
}
