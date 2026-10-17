import 'dart:collection';

import 'dataset.dart';

/// The value of an `SQ` element: an ordered, unmodifiable list of item
/// datasets.
///
/// The list itself can't change; replace the whole sequence with
/// `Dataset.set` to add or remove items. Each item is an ordinary [Dataset],
/// and editing an item marks the sequence as changed when it is written.
final class Sequence extends UnmodifiableListView<Dataset> {
  /// A sequence of [items], in order.
  Sequence(Iterable<Dataset> items) : super(List.of(items, growable: false));

  @override
  String toString() => 'Sequence($length item${length == 1 ? '' : 's'})';
}
