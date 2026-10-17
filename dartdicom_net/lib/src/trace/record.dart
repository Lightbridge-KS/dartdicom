import 'dart:typed_data';

import 'trace.dart';

// How the layers record PDU events (F5): the level check, and the rule that
// bytes carrying element values appear only with showValues. Not exported;
// the public trace API is trace.dart.

/// Records PDU events for the layers that send and receive PDUs.
extension PduRecording on Trace {
  /// Records one PDU, or a transport event, at [TraceLevel.pdu]. Its [bytes]
  /// appear at [TraceLevel.hex] unless they carry element values (a
  /// P-DATA-TF), which only [Trace.showValues] shows.
  void recordPdu(
      {required bool outgoing,
      required String summary,
      String? transition,
      Uint8List? bytes,
      bool carriesValues = false}) {
    if (!includes(TraceLevel.pdu)) return;
    final showBytes = includes(TraceLevel.hex) &&
        bytes != null &&
        (!carriesValues || showValues);
    record(PduTrace(
        outgoing: outgoing,
        summary: summary,
        transition: transition,
        bytes: showBytes ? bytes : null));
  }
}
