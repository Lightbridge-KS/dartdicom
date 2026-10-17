import '../../dataset/element.dart';
import '../../dataset/read_report.dart';
import '../../dictionary/dictionary.dart';
import '../../tag/tag.dart';
import '../../vr/value_codec.dart' show numberSize;
import '../../vr/vr.dart';
import 'header.dart';
import 'source_reader.dart';

// The C-10 checks that leave the data as it is and only report it
// (wrongLength, multipleValues, staleGroupLength).

/// Reports a numeric length that doesn't fit the VR, and several values
/// where the dictionary allows one (DA1, checked on the raw bytes so reads
/// stay lazy).
void checkElement(
    DataElement element, ElementHeader header, List<Repair> repairs) {
  final length = header.length;
  if (header.undefinedLength || length == 0) return;
  final vr = element.vr;
  final size = numberSize(vr);
  if (size != null && length % size != 0) {
    repairs.add(Repair(RepairKind.wrongLength,
        tag: element.tag, offset: header.valueStart));
  }
  if (Dictionary.standard.entry(element.tag)?.vm != '1') return;
  final raw = rawValueOf(element)!;
  final several = size != null
      ? length >= 2 * size
      : _multiValueText.contains(vr) &&
          !raw.isDeferred &&
          raw.bytes.contains(0x5C);
  if (several) {
    repairs.add(Repair(RepairKind.multipleValues,
        tag: element.tag, offset: header.valueStart));
  }
}

/// Text VRs that can hold several values, split on backslash.
const _multiValueText = {
  Vr.AE, Vr.AS, Vr.CS, Vr.DA, Vr.DS, Vr.DT, Vr.IS, Vr.LO, Vr.PN, //
  Vr.SH, Vr.TM, Vr.UC, Vr.UI,
};

/// Checks each group length (gggg,0000) against the group it measures, and
/// reports one that is stale. One per level read.
final class GroupLengthCheck {
  GroupLengthCheck(this.reader, this.repairs);

  final SourceReader reader;
  final List<Repair> repairs;
  int? _group;
  int? _groupStart;
  int? _groupLength;

  /// The element with [tag] at [at] is next: a new group closes the last.
  void enter(int tag, int at) {
    if (tag >> 16 == _group) return;
    close(at);
    _group = tag >> 16;
  }

  /// The element with [tag] was read, up to [end]: if it is a group length,
  /// its group starts there.
  void found(int tag, RawValue raw, int end) {
    if (tag & 0xFFFF == 0x0000 && raw.length == 4) {
      _groupStart = end;
      _groupLength = reader.u32Of(raw.bytes);
    }
  }

  /// The group being measured ends at [upTo].
  void close(int upTo) {
    final start = _groupStart;
    if (start != null && _groupLength != upTo - start) {
      repairs.add(Repair(RepairKind.staleGroupLength,
          tag: Tag.of(_group!, 0), offset: start));
    }
    _groupStart = null;
  }

  /// The group isn't read to its end, so its length can't be checked.
  void abandon() => _groupStart = null;
}
