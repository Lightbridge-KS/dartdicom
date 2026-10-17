import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../errors.dart';
import '../fsm/table.dart';
import '../pdu/pdus.dart';
import '../transport/transport.dart';
import 'framer.dart';
import '../timeouts.dart';
import '../trace/trace.dart';

/// The DICOM Upper Layer service for one association (PS3.8 §9), in either
/// role: PDUs in and out over a [Transport], every event checked against
/// the state machine [transitions].
///
/// **One read is always pending** while the transport is open (blueprint
/// F42): the DUL notices a peer's release, abort or closed connection even
/// while no operation runs. A PDU for the association layer (A-ASSOCIATE
/// RQ/AC, P-DATA-TF) waits for [receive]; the next read starts only once it
/// is taken, so a slow consumer slows the peer (one PDU of read-ahead).
///
/// **The end is recorded.** Once the association ends, by an abort, a
/// rejection, a closed connection, a protocol violation, a timeout or a
/// release by the peer, every later [send], [receive] and [release] throws
/// why.
///
/// **Timers** ([Timeouts]): ACSE while waiting for A-ASSOCIATE-AC/RJ or
/// A-RELEASE-RP; ARTIM (the ACSE value) in Sta2 and Sta13; network while
/// established and not [busy]. Each runs inside the DUL, so its expiry
/// fails the pending call with a [DimseTimeout].
final class Dul {
  /// The DUL of the requestor, over a transport that just connected.
  Dul.requestor(Transport transport,
      {Timeouts timeouts = const Timeouts(), Trace? trace})
      : this._(transport, UlEvent.evt1, timeouts, trace, isRequestor: true);

  /// The DUL of the acceptor, over a transport a listener just accepted.
  Dul.acceptor(Transport transport,
      {Timeouts timeouts = const Timeouts(), Trace? trace})
      : this._(transport, UlEvent.evt5, timeouts, trace, isRequestor: false);

  Dul._(this._transport, UlEvent opening, this.timeouts, this.trace,
      {required this.isRequestor}) {
    _pdus = StreamIterator(
        _transport.incoming.transform(PduFramer(maxLength: _pduCap)));
    _local(opening); // AE-1 or AE-5: the transport is already connected
    if (!isRequestor) _startTimer(TimeoutKind.acse); // ARTIM, Sta2
    unawaited(_read());
  }

  /// The timers' settings.
  final Timeouts timeouts;

  /// Where PDUs and transitions are traced, if anywhere (N-14).
  final Trace? trace;

  /// The last local transition, traced with the PDU it sends.
  String? _localTransition;

  /// Whether this side requested the association.
  final bool isRequestor;

  final Transport _transport;
  late final StreamIterator<Uint8List> _pdus;

  /// An acceptor takes PDUs of at most 1 MiB until it has an association,
  /// so connections that never associate can't each hold 64 MiB.
  static const _preAssociationCap = 1 << 20;

  int _pduCap() =>
      !isRequestor && (_state == UlState.sta2 || _state == UlState.sta3)
          ? _preAssociationCap
          : maxPduBytes;
  var _state = UlState.sta1;

  /// PDUs for the association layer, at most one (the read-ahead).
  final _inbox = Queue<Pdu>();
  Completer<void>? _arrived;
  Completer<void>? _taken;

  final _ended = Completer<void>();
  DimseException? _cause;
  var _releasedByPeer = false;
  var _closedLocally = false;

  /// The ACSE or ARTIM timer, whichever is running.
  Timer? _timer;
  Timer? _idle;
  var _busy = false;

  /// The current state of the state machine.
  UlState get state => _state;

  /// Completes when the association has ended, however it did.
  Future<void> get ended => _ended.future;

  /// Why the association ended abnormally, or `null` while it is open or
  /// after a release.
  DimseException? get cause => _cause;

  /// Whether an operation runs (SCU) or a request is being served (SCP).
  /// The network timer runs only while this is false.
  bool get busy => _busy;
  set busy(bool value) {
    _busy = value;
    _armIdle();
  }

  /// Sends A-ASSOCIATE-RQ and waits for the answer: the A-ASSOCIATE-AC, or
  /// an [AssociationRejected] for an A-ASSOCIATE-RJ.
  Future<AssociateAc> requestAssociation(AssociateRq rq) async {
    _local(UlEvent.evt2); // AE-2
    await _transmit(rq);
    _startTimer(TimeoutKind.acse);
    final answer = await receive();
    if (answer is AssociateAc) return answer;
    throw await _violation('expected A-ASSOCIATE-AC or -RJ, but got $answer');
  }

  /// Waits for the requestor's A-ASSOCIATE-RQ (acceptor).
  Future<AssociateRq> receiveRequest() async {
    final request = await receive();
    if (request is AssociateRq) return request;
    throw await _violation('expected A-ASSOCIATE-RQ, but got $request');
  }

  /// Accepts the association with [ac] (AE-7).
  Future<void> accept(AssociateAc ac) async {
    _local(UlEvent.evt7);
    await _transmit(ac);
    _armIdle();
  }

  /// Rejects the association with [rj] (AE-8); the requestor then closes
  /// the connection.
  Future<void> reject(AssociateRj rj) async {
    _local(UlEvent.evt8);
    _end(AssociationAborted('this side rejected the association'));
    await _transmit(rj);
    _startTimer(TimeoutKind.acse); // ARTIM: the requestor closes
  }

  /// Sends one P-DATA-TF (DT-1).
  Future<void> send(PDataTf pdu) async {
    _throwIfEnded();
    _local(UlEvent.evt9);
    await _transmit(pdu);
  }

  /// The next PDU for the association layer: A-ASSOCIATE-AC (Sta5),
  /// A-ASSOCIATE-RQ (Sta2), or P-DATA-TF (Sta6). `null` once the
  /// association has been released, by either side.
  ///
  /// Throws the recorded cause once it ended abnormally: an
  /// [AssociationAborted], [AssociationRejected] or
  /// [DimseProtocolException].
  Future<Pdu?> receive() async {
    while (_inbox.isEmpty) {
      if (_ended.isCompleted) {
        if (_cause case final cause?) throw cause;
        return null;
      }
      await (_arrived ??= Completer<void>()).future;
    }
    final pdu = _inbox.removeFirst();
    _wake(_taken);
    _taken = null;
    return pdu;
  }

  /// Sends A-RELEASE-RQ and waits for A-RELEASE-RP (AR-1, AR-3), through a
  /// release collision if the peer requests release too. P-DATA that
  /// arrives meanwhile is discarded.
  ///
  /// Returns at once if the association was already released; throws the
  /// recorded cause if it ended any other way.
  Future<void> release() async {
    if (_ended.isCompleted) {
      if (_cause case final cause?) throw cause;
      return;
    }
    _local(UlEvent.evt11);
    await _transmit(const ReleaseRq());
    _startTimer(TimeoutKind.acse);
    await _ended.future;
    if (_cause case final cause?) throw cause;
  }

  /// Aborts the association (A-ABORT, service user) and closes the
  /// connection; [because] is recorded as the cause. Does nothing once the
  /// association has ended.
  Future<void> abort({DimseException? because}) async {
    if (_ended.isCompleted) return;
    _end(because ?? AssociationAborted('this side aborted the association'));
    // Before an A-ASSOCIATE-RQ (Sta2) there is nothing to abort: closing the
    // connection is all (PS3.8 leaves Evt15 blank there).
    if (_state != UlState.sta2 && _local(UlEvent.evt15) == UlAction.aa1) {
      await _sendAbort(source: 0, reason: 0);
    }
    await _closeLocally();
  }

  // ── The reader ────────────────────────────────────────────────────────────

  /// Reads PDUs until the transport closes, one at a time, and acts on each.
  /// Nothing escapes it: every failure ends the association with a cause.
  Future<void> _read() async {
    try {
      while (!_closedLocally) {
        while (_inbox.isNotEmpty && !_ended.isCompleted) {
          await (_taken ??= Completer<void>()).future;
        }
        if (_closedLocally) return;
        final Uint8List bytes;
        try {
          if (!await _pdus.moveNext()) {
            if (!_closedLocally) await _received(UlEvent.evt17, null);
            return;
          }
          bytes = _pdus.current;
        } on FormatException catch (e) {
          await _invalid(e.message);
          continue;
        } on Object {
          // The connection failed: to the state machine, it closed.
          if (!_closedLocally) await _received(UlEvent.evt17, null);
          return;
        }
        final Pdu pdu;
        try {
          pdu = Pdu.decode(bytes);
        } on FormatException catch (e) {
          await _invalid(e.message);
          continue;
        }
        await _received(_eventOf(pdu), pdu, bytes: bytes);
      }
    } on Object catch (e) {
      _end(DimseProtocolException('the DUL failed (${e.runtimeType})'));
      await _closeLocally();
    }
  }

  static UlEvent _eventOf(Pdu pdu) => switch (pdu) {
        AssociateRq() => UlEvent.evt6,
        AssociateAc() => UlEvent.evt3,
        AssociateRj() => UlEvent.evt4,
        PDataTf() => UlEvent.evt10,
        ReleaseRq() => UlEvent.evt12,
        ReleaseRp() => UlEvent.evt13,
        Abort() => UlEvent.evt16,
      };

  /// Performs the action for a received [event] ([pdu] for a PDU event).
  Future<void> _received(UlEvent event, Pdu? pdu,
      {String? invalid, DimseException? because, Uint8List? bytes}) async {
    final from = _state;
    _armIdle(); // anything received restarts the network timer
    final cell = transition(from, event);
    _trace(
        outgoing: false,
        summary: pdu == null
            ? (invalid == null
                ? 'the connection closed'
                : 'an invalid PDU ($invalid)')
            : '${pdu.summary} (${bytes?.length ?? 0} B)',
        transition: cell == null
            ? '${_name(from)} + ${_name(event)}: blank'
            : _transitionText(
                from,
                event,
                cell.$1,
                cell.$1 == UlAction.ar8
                    ? (isRequestor ? UlState.sta9 : UlState.sta10)
                    : cell.$2),
        pdu: pdu,
        bytes: bytes);
    if (cell == null) {
      // A blank cell: the peer did something PS3.8 gives no meaning here.
      return _protocolAbort('unexpected ${pdu ?? event.name} in ${from.name}',
          reason: 2);
    }
    final (action, nominal) = cell;
    _state = action == UlAction.ar8
        ? (isRequestor ? UlState.sta9 : UlState.sta10)
        : nominal;
    switch (action) {
      case UlAction.ae3:
        _stopTimer();
        _deliver(pdu!);
        _armIdle();
      case UlAction.ae6:
        _stopTimer(); // ARTIM
        _deliver(pdu!);
      case UlAction.dt2:
        _deliver(pdu!);
      case UlAction.ae4:
        final rj = pdu! as AssociateRj;
        _end(AssociationRejected(
            result: rj.result, source: rj.source, reason: rj.reason));
        await _closeLocally();
      case UlAction.ar2:
        // The peer requests release: answer at once (Evt14 → AR-4).
        _releasedByPeer = true;
        _end(null);
        _local(UlEvent.evt14);
        await _transmit(const ReleaseRp());
        _startTimer(TimeoutKind.acse); // ARTIM: the requestor closes
      case UlAction.ar3:
        _end(null);
        await _closeLocally();
      case UlAction.ar5:
        await _closeLocally();
      case UlAction.ar6:
        break; // P-DATA after our release request: discarded
      case UlAction.ar8:
        // A release collision (PS3.8 §9.2.8): the requestor answers first.
        if (isRequestor) {
          _local(UlEvent.evt14); // AR-9 → Sta11
          await _transmit(const ReleaseRp());
        }
      case UlAction.ar10:
        _end(null); // the release is confirmed; answer the peer's in turn
        _local(UlEvent.evt14); // AR-4 → Sta13
        await _transmit(const ReleaseRp());
        _startTimer(TimeoutKind.acse); // ARTIM: the requestor closes
      case UlAction.aa1:
        // A PDU before the A-ASSOCIATE-RQ.
        _end(because ??
            DimseProtocolException(
                'unexpected ${pdu ?? event.name} before A-ASSOCIATE-RQ'));
        await _sendAbort(source: 0, reason: 0);
        await _closeLocally();
      case UlAction.aa2:
        _end(AssociationAborted('the peer aborted the association'));
        await _closeLocally();
      case UlAction.aa3:
        final abort = pdu! as Abort;
        _end(AssociationAborted(abort.source == 2
            ? 'the peer\'s DICOM service aborted the association '
                '(reason ${abort.reason})'
            : 'the peer aborted the association'));
        await _closeLocally();
      case UlAction.aa4:
        _end(AssociationAborted(
            'the connection closed before the association was released'));
        await _closeLocally();
      case UlAction.aa5:
        _end(AssociationAborted(
            'the connection closed before an association was requested'));
        await _closeLocally();
      case UlAction.aa6:
        break; // ignored while the transport closes
      case UlAction.aa7:
        await _sendAbort(source: 2, reason: invalid == null ? 2 : 1);
      case UlAction.aa8:
        _end(because ??
            DimseProtocolException('unexpected ${pdu ?? event.name} in '
                '${from.name}'));
        await _sendAbort(source: 2, reason: invalid == null ? 2 : 1);
        await _closeLocally();
      case UlAction.ae1 ||
            UlAction.ae2 ||
            UlAction.ae5 ||
            UlAction.ae7 ||
            UlAction.ae8 ||
            UlAction.dt1 ||
            UlAction.ar1 ||
            UlAction.ar4 ||
            UlAction.ar7 ||
            UlAction.ar9:
        // Local actions: the table never maps a received event to one.
        throw StateError('$action for a received ${event.name}');
    }
  }

  /// An invalid PDU (Evt19): an abort with reason 1 (unrecognized PDU).
  Future<void> _invalid(String problem) => _received(UlEvent.evt19, null,
      invalid: problem,
      because: DimseProtocolException('invalid PDU ($problem)'));

  /// Aborts for a peer's protocol violation and records it.
  Future<void> _protocolAbort(String problem, {required int reason}) async {
    _end(DimseProtocolException(problem));
    _state = UlState.sta13;
    await _sendAbort(source: 2, reason: reason);
    await _closeLocally();
  }

  /// A violation found above the DUL (an answer that makes no sense): the
  /// association is aborted, and the exception returned for throwing.
  Future<DimseProtocolException> _violation(String problem) async {
    await _protocolAbort(problem, reason: 2);
    return _cause! as DimseProtocolException;
  }

  // ── Timers ────────────────────────────────────────────────────────────────

  void _startTimer(TimeoutKind kind) {
    _timer?.cancel();
    final after = timeouts.acse;
    _timer = Timer(after, () => unawaited(_expired(kind, after)));
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// Restarts the network timer while established and idle; stops it
  /// otherwise.
  void _armIdle() {
    _idle?.cancel();
    _idle = null;
    if (_busy || _state != UlState.sta6 || _ended.isCompleted) return;
    final after = timeouts.network;
    _idle = Timer(after, () => unawaited(_expired(TimeoutKind.network, after)));
  }

  /// A timer expired: ARTIM in Sta2 or Sta13 closes the connection (Evt18,
  /// AA-2); any other aborts.
  Future<void> _expired(TimeoutKind kind, Duration after) async {
    if (_closedLocally) return;
    if (_state == UlState.sta2 || _state == UlState.sta13) {
      _end(DimseTimeout(kind, after));
      return _closeLocally();
    }
    await abort(because: DimseTimeout(kind, after));
  }

  // ── Plumbing ──────────────────────────────────────────────────────────────

  void _deliver(Pdu pdu) {
    _inbox.add(pdu);
    _wake(_arrived);
    _arrived = null;
  }

  /// Records the end, once: [cause], or `null` for a release.
  void _end(DimseException? cause) {
    if (_ended.isCompleted) return;
    _idle?.cancel();
    if (_state != UlState.sta13) _stopTimer();
    _cause = cause;
    if (cause != null) _inbox.clear();
    _ended.complete();
    _wake(_arrived);
    _arrived = null;
    _wake(_taken);
    _taken = null;
  }

  void _throwIfEnded() {
    if (!_ended.isCompleted) return;
    if (_cause case final cause?) throw cause;
    if (_releasedByPeer) {
      throw AssociationAborted('the peer released the association');
    }
    throw StateError('the association was released; associate again');
  }

  /// Applies a local request [event], returning its action. A blank cell is
  /// the recorded cause once the association has ended, else a
  /// programming error.
  UlAction _local(UlEvent event) {
    final cell = transition(_state, event);
    if (cell == null) {
      _throwIfEnded();
      throw StateError('${event.name} is not allowed in ${_state.name}');
    }
    _localTransition = _transitionText(_state, event, cell.$1, cell.$2);
    _state = cell.$2;
    return cell.$1;
  }

  /// Sends [pdu]. A failed send means the connection is gone.
  Future<void> _transmit(Pdu pdu) async {
    final bytes = pdu.encode();
    _trace(
        outgoing: true,
        summary: '${pdu.summary} (${bytes.length} B)',
        transition: _localTransition,
        pdu: pdu,
        bytes: bytes);
    _localTransition = null;
    try {
      await _transport.send(bytes);
    } on Object {
      _end(AssociationAborted('the connection failed'));
      await _closeLocally();
      throw _cause!;
    }
  }

  Future<void> _sendAbort({required int source, required int reason}) async {
    final abort = Abort(source: source, reason: reason);
    final bytes = abort.encode();
    _trace(
        outgoing: true,
        summary: '${abort.summary} (${bytes.length} B)',
        transition: _localTransition,
        pdu: abort,
        bytes: bytes);
    _localTransition = null;
    try {
      await _transport.send(bytes);
    } on Object {
      // The connection may already be gone; closing is all that is left.
    }
  }

  /// Closes the transport and stops reading it, so no subscription keeps
  /// the isolate alive. A closed transport ends the state machine (Sta1).
  Future<void> _closeLocally() async {
    if (_closedLocally) return;
    _closedLocally = true;
    _state = UlState.sta1;
    _stopTimer();
    _idle?.cancel();
    _end(_cause ?? AssociationAborted('the connection was closed'));
    try {
      await _transport.close();
    } on Object {
      // Already closed.
    }
    await _pdus.cancel();
  }

  /// Records one PDU (or transport event) at [TraceLevel.pdu], with its
  /// bytes at [TraceLevel.hex] unless they are P-DATA, which carries values
  /// ([Trace.showValues] shows those too).
  void _trace(
      {required bool outgoing,
      required String summary,
      required String? transition,
      required Pdu? pdu,
      required Uint8List? bytes}) {
    final trace = this.trace;
    if (trace == null || !trace.includes(TraceLevel.pdu)) return;
    final showBytes = trace.includes(TraceLevel.hex) &&
        bytes != null &&
        (pdu is! PDataTf || trace.showValues);
    trace.record(PduTrace(
        outgoing: outgoing,
        summary: summary,
        transition: transition,
        bytes: showBytes ? bytes : null));
  }

  static String _transitionText(
          UlState from, UlEvent event, UlAction action, UlState to) =>
      '${_name(from)} + ${_name(event)} → ${_name(action)} → ${_name(to)}';

  /// `sta6` → `Sta6`, `evt10` → `Evt10`, `dt2` → `DT-2`.
  static String _name(Enum e) => switch (e) {
        UlAction() =>
          '${e.name.substring(0, 2).toUpperCase()}-${e.name.substring(2)}',
        _ => '${e.name[0].toUpperCase()}${e.name.substring(1)}',
      };

  static void _wake(Completer<void>? waiter) {
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }
}
