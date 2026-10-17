// Hand-built DICOM bytes, for tests that need data the writer won't make:
// odd lengths, missing VRs, damaged structure, values chosen byte by byte.
// Platform-free: the lenient-read tests run on node too.
//
// The kit keeps its own long-VR table and padding rule rather than using
// the library's: a test must not borrow the rule it checks.

/// The undefined length, 0xFFFFFFFF (PS3.5 §7.1).
const undefinedLength = 0xFFFFFFFF;

/// The VRs whose Explicit VR header has two reserved bytes and a 4-byte
/// length (PS3.5 §7.1.2).
const _longVrs = {
  'OB', 'OD', 'OF', 'OL', 'OV', 'OW', 'SQ', 'SV', 'UC', 'UN', 'UR', 'UT', //
  'UV',
};

/// [v] as 2 bytes, little-endian unless [big].
List<int> u16(int v, {bool big = false}) =>
    big ? [v >> 8 & 0xFF, v & 0xFF] : [v & 0xFF, v >> 8 & 0xFF];

/// [v] as 4 bytes, little-endian.
List<int> u32(int v) =>
    [v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24 & 0xFF];

/// Tag [t] (`0xggggeeee`): its group, then its element, each little-endian
/// unless [big].
List<int> tag(int t, {bool big = false}) =>
    [...u16(t >> 16 & 0xFFFF, big: big), ...u16(t & 0xFFFF, big: big)];

/// Text padded to even length: UIDs ([uid]) with NUL, the rest with a space.
List<int> text(String s, {bool uid = false}) =>
    [...s.codeUnits, if (s.length.isOdd) uid ? 0 : 0x20];

/// An Explicit VR Little Endian element: tag [t], VR [vr], then [value];
/// [length] overrides the value's own length.
List<int> ex(int t, String vr, List<int> value, {int? length}) => [
      ...tag(t),
      ...vr.codeUnits,
      if (_longVrs.contains(vr)) ...[0, 0, ...u32(length ?? value.length)],
      if (!_longVrs.contains(vr)) ...u16(length ?? value.length),
      ...value,
    ];

/// An Implicit VR Little Endian element: tag [t], then [value]; [length]
/// overrides the value's own length.
List<int> im(int t, List<int> value, {int? length}) =>
    [...tag(t), ...u32(length ?? value.length), ...value];

/// The header of an Item of [body]'s length; the caller adds [body].
List<int> item(List<int> body) => [...tag(0xFFFEE000), ...u32(body.length)];

/// An Item of undefined length holding [body], with its Item Delimitation
/// Item.
List<int> undefinedItem(List<int> body) => [
      ...tag(0xFFFEE000),
      ...u32(undefinedLength),
      ...body,
      ...tag(0xFFFEE00D),
      ...u32(0),
    ];

/// A Sequence Delimitation Item.
List<int> get sequenceEnd => [...tag(0xFFFEE0DD), ...u32(0)];
