import '../errors.dart';

/// The outcome of a DIMSE operation: a response's Status (0000,0900), by
/// its class in PS3.7 Annex C.
///
/// Sealed, with no default that means success (blueprint F12): match on it,
/// or call [orThrow].
///
/// ```dart
/// switch (await assoc.sendCEcho()) {
///   case DimseSuccess(): ...
///   case DimseFailure(:final code): ...
///   default: ...
/// }
/// ```
sealed class DimseStatus {
  const DimseStatus._(this.code);

  /// Classifies a Status value.
  factory DimseStatus(int code) => switch (code) {
        0x0000 => DimseSuccess._(code),
        0xFF00 || 0xFF01 => DimsePending._(code),
        0xFE00 => DimseCancel._(code),
        0x0001 || 0x0107 || 0x0116 => DimseWarning._(code),
        >= 0xB000 && <= 0xBFFF => DimseWarning._(code),
        _ => DimseFailure._(code),
      };

  /// The Status value, e.g. `0xA700`.
  final int code;

  /// This status, or a [DimseFailureException] if it is a failure.
  DimseStatus orThrow() => this is DimseFailure
      ? throw DimseFailureException(this as DimseFailure)
      : this;

  /// The code as 4 hex digits, e.g. `0xA700`.
  String get hex => '0x${code.toRadixString(16).padLeft(4, '0').toUpperCase()}';

  @override
  bool operator ==(Object other) =>
      other is DimseStatus &&
      other.runtimeType == runtimeType &&
      other.code == code;

  @override
  int get hashCode => code.hashCode;
}

/// 0x0000: the operation succeeded.
final class DimseSuccess extends DimseStatus {
  const DimseSuccess._(super.code) : super._();

  @override
  String toString() => 'DimseSuccess($hex)';
}

/// 0xFF00 / 0xFF01: more responses follow (C-FIND matches, retrieve
/// progress). Never the final status of an operation.
final class DimsePending extends DimseStatus {
  const DimsePending._(super.code) : super._();

  @override
  String toString() => 'DimsePending($hex)';
}

/// 0x0001, 0x0107, 0x0116, 0xBxxx: done, with a warning (e.g. some
/// sub-operations failed).
final class DimseWarning extends DimseStatus {
  const DimseWarning._(super.code) : super._();

  @override
  String toString() => 'DimseWarning($hex)';
}

/// 0xFE00: the operation was cancelled.
final class DimseCancel extends DimseStatus {
  const DimseCancel._(super.code) : super._();

  @override
  String toString() => 'DimseCancel($hex)';
}

/// Any other code (0xAxxx, 0xCxxx, 0x01xx, 0x02xx): the operation failed.
final class DimseFailure extends DimseStatus {
  const DimseFailure._(super.code) : super._();

  @override
  String toString() => 'DimseFailure($hex)';
}
