/// DocBook table parsing for PS3.6 and PS3.7, and normalization of the rows
/// into dictionary records.
library;

import 'package:dartdicom/src/vr/vr.dart';
import 'package:xml/xml.dart';

/// A table row keyed by column header (the unlabeled column is `Retired`).
typedef Row = Map<String, String>;

/// The rows of the table whose caption is [caption].
List<Row> parseTable(XmlDocument doc, String caption) {
  for (final table in doc.findAllElements('table')) {
    if (_clean(table.getElement('caption')?.innerText ?? '') != caption) {
      continue;
    }
    final headers = [
      for (final th in table.getElement('thead')!.findAllElements('th'))
        _clean(th.innerText).isEmpty ? 'Retired' : _clean(th.innerText),
    ];
    return [
      for (final tr in table.getElement('tbody')!.findElements('tr'))
        {
          for (final (i, td) in tr.findElements('td').indexed)
            if (i < headers.length) headers[i]: _clean(td.innerText),
        },
    ];
  }
  throw StateError('no table captioned "$caption"');
}

String _clean(String s) =>
    s.replaceAll('​', '').replaceAll(RegExp(r'\s+'), ' ').trim();

/// A normalized data element (or command field) entry.
final class Element {
  Element({
    required this.tag,
    required this.vrs,
    required this.vm,
    required this.keyword,
    required this.name,
    required this.retired,
  });

  /// `GGGGEEEE`, uppercase hex; may contain `x` for repeating ranges.
  final String tag;
  final List<Vr> vrs;
  final String vm;
  final String keyword;
  final String name;
  final bool retired;

  bool get isRepeater => tag.contains('x');
}

/// Normalizes a PS3.6 or PS3.7 row, following the same rules as pydicom's
/// generator so the two can be compared.
Element elementFrom(Row row, {bool? retired}) {
  final tag = row['Tag']!
      .replaceAll(RegExp(r'[(),\s]'), '')
      .toUpperCase()
      .replaceAll('X', 'x');
  var keyword = row['Keyword'] ?? '';
  var name = row['Name'] ?? row['Message Field'] ?? '';
  var vrText = row['VR'] ?? '';
  var vm = (row['VM'] ?? '').split(' or ').first;
  var isRetired = retired ?? _isRetired(row['Retired'] ?? '');

  // Retired placeholders with no keyword or name (PS3.6 §6, note 3).
  if (keyword.isEmpty && name.isEmpty) {
    isRetired = true;
    if (vrText.isEmpty) vrText = 'OB';
    if (vm.isEmpty) vm = '1';
  }
  // The item and delimitation tags have no VR ("See Note").
  final vrs = vrText == 'See Note' || vrText.isEmpty
      ? <Vr>[]
      : [
          for (final code in vrText.split(' or '))
            Vr.fromCode(code.trim()) ??
                (throw FormatException('unknown VR "$code" for ($tag)')),
        ];
  return Element(
    tag: tag,
    vrs: vrs,
    vm: vm,
    keyword: keyword,
    name: name,
    retired: isRetired,
  );
}

bool _isRetired(String marker) =>
    marker == 'RET' || marker.startsWith('RET (') || marker.startsWith('RET -');

/// A normalized UID registry entry (PS3.6 Table A-1).
final class UidEntry {
  UidEntry(this.value, this.name, this.keyword, this.type, this.retired);

  final String value;
  final String name;
  final String keyword;
  final String type;
  final bool retired;
}

UidEntry uidFrom(Row row) {
  var name = row['UID Name']!;
  final retired = name.contains('(Retired)');
  name = name.replaceAll('(Retired)', '').trim();
  return UidEntry(
    row['UID Value']!,
    name,
    row['UID Keyword'] ?? '',
    row['UID Type'] ?? '',
    retired,
  );
}
