import '../tag/tag.dart';

/// A private creator's block of elements in one odd group (PS3.5 §7.8.1):
/// the creator ID in (gggg,00BB) reserves elements (gggg,BB00–BBFF).
///
/// Get one with `Dataset.privateBlock`, then read and write its elements
/// through the untyped getters and `setRaw` (surface S9):
///
/// ```dart
/// final acme = ds.privateBlock(0x0009, 'ACME 1.0', create: true)!;
/// ds.setRaw(acme.tag(0x01), Vr.LO, ['scanner-7']);
/// ds.getStrings(acme.tag(0x01));   // ['scanner-7']
/// ```
final class PrivateBlock {
  const PrivateBlock(this.group, this.creator, this.slot);

  /// The odd group, e.g. `0x0009`.
  final int group;

  /// The private creator ID.
  final String creator;

  /// The reserved block, 0x10–0xFF: the creator sits at (group, slot).
  final int slot;

  /// The tag of the block's element [offset] (0x00–0xFF):
  /// `(group, slot << 8 | offset)`.
  Tag tag(int offset) {
    RangeError.checkValueInInterval(offset, 0, 0xFF, 'offset');
    return Tag.of(group, slot << 8 | offset);
  }

  @override
  String toString() =>
      'PrivateBlock(${group.toRadixString(16).padLeft(4, '0')}, '
      'slot ${slot.toRadixString(16)})';
}
