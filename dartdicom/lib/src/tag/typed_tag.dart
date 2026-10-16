import 'tag.dart';

/// A tag whose dictionary entry allows exactly one value (VM `1`), typed
/// with the value's Dart type [T] (data architecture §3.4, DA1).
///
/// Read it with `Dataset.get` / `Dataset.require`. Passing it where a [Many]
/// is expected is a compile error. At runtime it is still just the tag
/// number.
extension type const One<T extends Object>(int value) implements Tag {}

/// A tag whose dictionary entry allows several values (VM `1-n`, `2`, …),
/// typed with the Dart type [T] of each value.
///
/// Read it with `Dataset.getAll`, which returns a `List<T>`.
extension type const Many<T extends Object>(int value) implements Tag {}
