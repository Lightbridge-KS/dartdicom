import 'package:dartdicom/dartdicom.dart';

import '../dimse/message.dart';
import '../dimse/status.dart';

/// Where a C-GET or C-MOVE stands: the sub-operation counts of one
/// response (PS3.7 §9.3.3.2, PRD N-12).
final class RetrieveProgress {
  const RetrieveProgress({
    required this.status,
    required this.remaining,
    required this.completed,
    required this.failed,
    required this.warning,
  });

  factory RetrieveProgress.fromResponse(DimseMessage rsp) => RetrieveProgress(
        status: rsp.outcome,
        remaining: rsp.command.get(DicomTags.numberOfRemainingSuboperations),
        completed:
            rsp.command.get(DicomTags.numberOfCompletedSuboperations) ?? 0,
        failed: rsp.command.get(DicomTags.numberOfFailedSuboperations) ?? 0,
        warning: rsp.command.get(DicomTags.numberOfWarningSuboperations) ?? 0,
      );

  /// [DimsePending] while sub-operations continue; the last event carries
  /// the operation's final status.
  final DimseStatus status;

  /// Sub-operations still to come; `null` when the response doesn't say
  /// (usual in a final response).
  final int? remaining;

  final int completed;
  final int failed;
  final int warning;

  /// All sub-operations, done and remaining.
  int get total => (remaining ?? 0) + completed + failed + warning;

  /// Whether this is the last event of the retrieve.
  bool get isFinal => status is! DimsePending;

  @override
  String toString() => 'RetrieveProgress($status, remaining: $remaining, '
      'completed: $completed, failed: $failed, warning: $warning)';
}
