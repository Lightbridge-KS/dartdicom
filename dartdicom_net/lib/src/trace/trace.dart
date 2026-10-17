import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';

// The protocol trace by layer (PRD N-14): DIMSE messages, then PDUs with
// the state machine's transitions, then hex. It shows no element value
// unless asked to (I-9, blueprint F5): datasets appear by size, instance UIDs
// and error comments are masked, and P-DATA bytes are never dumped.
// Modelled on pynetdicom's debug handlers. This library sits below every
// layer, so it holds core types and strings only.

/// How much the trace shows, each level including the ones before it.
enum TraceLevel {
  /// DIMSE messages: command fields, IDs, SOP classes, statuses, counts.
  dimse,

  /// Also each PDU in and out, with the state machine's transition.
  pdu,

  /// Also the bytes of the PDUs that carry no values (association,
  /// release, abort), as hex.
  hex,
}

/// Where trace events go: a logger, a capture in a test, a UI.
abstract interface class TraceSink {
  /// A sink that writes each event as one line to [write].
  factory TraceSink.lines(void Function(String line) write) = _LineSink;

  /// Takes one event. Throwing from here never disturbs the protocol.
  void record(TraceEvent event);
}

/// What to trace, and to which [sink].
final class Trace {
  const Trace(this.sink,
      {this.level = TraceLevel.dimse, this.showValues = false});

  final TraceSink sink;
  final TraceLevel level;

  /// Shows instance UIDs, error comments and P-DATA hex. For a test PACS
  /// only: the output then holds patient data.
  final bool showValues;

  /// Whether events of [level] are recorded.
  bool includes(TraceLevel level) => level.index <= this.level.index;

  /// Records [event], ignoring any failure of the sink.
  void record(TraceEvent event) {
    try {
      sink.record(event);
    } on Object {
      // A broken sink must not break the association.
    }
  }
}

/// One traced event, in or out.
sealed class TraceEvent {
  const TraceEvent({required this.outgoing});

  /// Sent by this side, or received from the peer.
  final bool outgoing;

  String get _arrow => outgoing ? '→' : '←';
}

/// A DIMSE message: its command elements, and its dataset by size.
final class DimseTrace extends TraceEvent {
  DimseTrace(
      {required super.outgoing,
      required this.contextId,
      required Dataset command,
      required this.datasetLength,
      required bool showValues})
      : name = _names[command.get(DicomTags.commandField)] ?? 'DIMSE message',
        fields = _fields(command, showValues);

  final int contextId;

  /// The message type, e.g. `C-FIND-RSP`.
  final String name;

  /// The command elements as `keyword value`, masked where they may hold
  /// values ([Trace.showValues] off).
  final List<String> fields;

  /// The dataset's size in bytes, or `null` for none.
  final int? datasetLength;

  static const _names = {
    0x0001: 'C-STORE-RQ', 0x8001: 'C-STORE-RSP', //
    0x0010: 'C-GET-RQ', 0x8010: 'C-GET-RSP',
    0x0020: 'C-FIND-RQ', 0x8020: 'C-FIND-RSP',
    0x0021: 'C-MOVE-RQ', 0x8021: 'C-MOVE-RSP',
    0x0030: 'C-ECHO-RQ', 0x8030: 'C-ECHO-RSP',
    0x0FFF: 'C-CANCEL-RQ',
  };

  /// Group length, Command Field and Command Data Set Type: the line's name
  /// and its dataset size say them.
  static const _implied = {0x00000000, 0x00000100, 0x00000800};

  static const _masked = {
    0x00001000, // Affected SOP Instance UID
    0x00001001, // Requested SOP Instance UID
    0x00000902, // Error Comment
  };

  static List<String> _fields(Dataset command, bool showValues) => [
        for (final e in command.elements)
          if (!_implied.contains(e.tag.value))
            '${Dictionary.standard.entry(e.tag)?.keyword ?? _hexTag(e.tag)} '
                '${!showValues && _masked.contains(e.tag.value) ? '***' : _value(e)}',
      ];

  static String _hexTag(Tag t) =>
      '(${(t.value >> 16).toRadixString(16).padLeft(4, '0')},'
      '${(t.value & 0xFFFF).toRadixString(16).padLeft(4, '0')})';

  static String _value(DataElement e) => switch (e.value) {
        final List<int> v when e.tag.value == 0x00000900 => v
            .map(
                (x) => '0x${x.toRadixString(16).padLeft(4, '0').toUpperCase()}')
            .join(','),
        final List<Object> v => v.join(','),
        final Object v => '$v',
      };

  @override
  String toString() => '$_arrow DIMSE $name ctx $contextId'
      '${fields.map((f) => ' | $f').join()}'
      '${datasetLength == null ? '' : ' | dataset $datasetLength B'}';
}

/// A PDU in or out (or a transport event), with the state machine's
/// transition and, at [TraceLevel.hex], its bytes.
final class PduTrace extends TraceEvent {
  const PduTrace(
      {required super.outgoing,
      required this.summary,
      this.transition,
      this.bytes});

  /// The PDU type and what it carries, without values.
  final String summary;

  /// `Sta6 + Evt10 → DT-2 → Sta6`, or `null`.
  final String? transition;

  /// The PDU's bytes, when the level is hex and they hold no values.
  final Uint8List? bytes;

  @override
  String toString() => '$_arrow PDU $summary'
      '${transition == null ? '' : ' | $transition'}'
      '${bytes == null ? '' : ' | ${_hex(bytes!)}'}';

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
}

final class _LineSink implements TraceSink {
  const _LineSink(this._write);

  final void Function(String) _write;

  @override
  void record(TraceEvent event) => _write('$event');
}
