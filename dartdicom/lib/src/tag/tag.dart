/// A DICOM attribute tag: `(group, element)` packed into 32 bits (PS3.5 §7.1).
///
/// At runtime a [Tag] *is* its `int` value, so it costs nothing to store or
/// compare. Tag numbers fit in 32 bits, so they are exact on every platform,
/// including dart2js.
///
/// It implements [Object] so that it is non-nullable, and so it works as a
/// `Set`/`Map` key or an `Object` argument. It deliberately does not
/// implement `int`, so integer arithmetic on a tag doesn't compile.
extension type const Tag(int value) implements Object {
  /// The tag for [group] and [element], e.g. `Tag.of(0x0010, 0x0010)`.
  const Tag.of(int group, int element)
      : assert(group >= 0 && group <= 0xFFFF),
        assert(element >= 0 && element <= 0xFFFF),
        value = group << 16 | element;

  /// The group number: the upper 16 bits.
  int get group => value >> 16;

  /// The element number: the lower 16 bits.
  int get element => value & 0xFFFF;

  /// Whether this is a private tag: an odd group other than 0001, 0003,
  /// 0005, 0007 and FFFF (PS3.5 §7.8.1).
  bool get isPrivate =>
      group.isOdd &&
      group != 0x0001 &&
      group != 0x0003 &&
      group != 0x0005 &&
      group != 0x0007 &&
      group != 0xFFFF;
}
