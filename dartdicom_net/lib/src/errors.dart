import 'package:dartdicom/dartdicom.dart';

import 'dimse/status.dart';
import 'timeouts.dart';

/// Something went wrong on an association: it was rejected or aborted, the
/// peer broke the protocol, or an operation's final status was a failure.
///
/// Sealed, so a `switch` over its subtypes is exhaustive. Messages say what
/// to do next and never contain element values (I-9).
sealed class DimseException extends DicomException {
  const DimseException(super.message);
}

/// The peer rejected the association (A-ASSOCIATE-RJ, PS3.8 §9.3.4).
final class AssociationRejected extends DimseException {
  AssociationRejected(
      {required this.result, required this.source, required this.reason})
      : super('AssociationRejected: the peer rejected the association '
            '${result == 1 ? 'permanently' : 'transiently'}: '
            '${describeAssociationRejection(source, reason)}');

  /// 1 permanent, 2 transient.
  final int result;

  /// 1 service user, 2 service provider (ACSE), 3 service provider
  /// (presentation).
  final int source;

  /// The reason code, by [source].
  final int reason;
}

/// The association ended without a release: the peer sent A-ABORT, or the
/// connection closed. Operations in progress fail with it.
final class AssociationAborted extends DimseException {
  AssociationAborted(String why,
      {this.source, this.reason, this.locallyCancelled = false})
      : super('AssociationAborted: $why');

  /// Numeric A-ABORT fields; absent for transport closure/local interruption.
  final int? source, reason;
  final bool locallyCancelled;
}

/// The peer broke the DICOM Upper Layer or DIMSE protocol; the association
/// has been aborted.
final class DimseProtocolException extends DimseException {
  DimseProtocolException(String problem)
      : super('DimseProtocolException: $problem; the association was aborted');
}

/// A timer of [Timeouts] expired: the association was aborted (or never
/// established), and the next call fails the same way.
final class DimseTimeout extends DimseException {
  DimseTimeout(this.kind, this.after)
      : super('DimseTimeout: ${kind.what} within the ${kind.setting} '
            'timeout (${_duration(after)})'
            '${kind == TimeoutKind.connect ? '' : ', so the association was aborted'}'
            '; raise Timeouts.${kind.setting} if the peer is slow');

  /// Which timer expired.
  final TimeoutKind kind;

  /// Its setting.
  final Duration after;
}

String _duration(Duration d) => d.inMilliseconds % 1000 == 0
    ? '${d.inSeconds} s'
    : '${d.inMilliseconds} ms';

/// A multi-response operation (C-FIND, C-GET, C-MOVE) ended with a failure
/// status, or [DimseStatus.orThrow] was called on one (surface S5).
final class DimseFailureException extends DimseException {
  DimseFailureException(this.status)
      : super('DimseFailureException: the operation failed with status '
            '${status.hex}');

  /// The failure status.
  final DimseFailure status;
}

String describeAssociationRejection(int source, int reason) =>
    switch ((source, reason)) {
      (1, 1) => 'no reason given',
      (1, 2) => 'application context name not supported',
      (1, 3) => 'calling AE title not recognized; register this AE title '
          'with the peer',
      (1, 7) => 'called AE title not recognized; check the called AE title',
      (2, 1) => 'no reason given (ACSE)',
      (2, 2) => 'protocol version not supported',
      (3, 1) => 'temporary congestion; retry later',
      (3, 2) => 'local limit exceeded; retry later',
      _ => 'source $source, reason $reason',
    };
