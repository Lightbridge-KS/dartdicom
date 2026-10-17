// The DICOM Upper Layer state machine (PS3.8 §9.2, Table 9-10) as data:
// (state, event) → (action, next state). It holds no I/O; the DUL performs
// the actions.

/// The 13 states of PS3.8 Table 9-10.
enum UlState {
  /// Idle.
  sta1,

  /// Transport connection open, awaiting A-ASSOCIATE-RQ (acceptor).
  sta2,

  /// Awaiting the local A-ASSOCIATE response (acceptor).
  sta3,

  /// Awaiting the transport connection to open (requestor).
  sta4,

  /// Awaiting A-ASSOCIATE-AC or -RJ (requestor).
  sta5,

  /// Association established, ready for data transfer.
  sta6,

  /// Awaiting A-RELEASE-RP.
  sta7,

  /// Awaiting the local A-RELEASE response.
  sta8,

  /// Release collision, requestor side: awaiting the local release response.
  sta9,

  /// Release collision, acceptor side: awaiting A-RELEASE-RP.
  sta10,

  /// Release collision, requestor side: awaiting A-RELEASE-RP.
  sta11,

  /// Release collision, acceptor side: awaiting the local release response.
  sta12,

  /// Awaiting the transport connection to close.
  sta13,
}

/// The 19 events of PS3.8 Table 9-10.
enum UlEvent {
  /// A-ASSOCIATE request (local user).
  evt1,

  /// Transport connection confirmed (local transport).
  evt2,

  /// A-ASSOCIATE-AC PDU received.
  evt3,

  /// A-ASSOCIATE-RJ PDU received.
  evt4,

  /// Transport connection indication (local transport).
  evt5,

  /// A-ASSOCIATE-RQ PDU received.
  evt6,

  /// A-ASSOCIATE response, accept (local user).
  evt7,

  /// A-ASSOCIATE response, reject (local user).
  evt8,

  /// P-DATA request (local user).
  evt9,

  /// P-DATA-TF PDU received.
  evt10,

  /// A-RELEASE request (local user).
  evt11,

  /// A-RELEASE-RQ PDU received.
  evt12,

  /// A-RELEASE-RP PDU received.
  evt13,

  /// A-RELEASE response (local user).
  evt14,

  /// A-ABORT request (local user).
  evt15,

  /// A-ABORT PDU received.
  evt16,

  /// Transport connection closed.
  evt17,

  /// ARTIM timer expired.
  evt18,

  /// Unrecognized or invalid PDU received.
  evt19,
}

/// The actions of PS3.8 §9.2.2, by their names in the standard.
enum UlAction {
  /// Issue a transport connect request.
  ae1,

  /// Send A-ASSOCIATE-RQ.
  ae2,

  /// Issue an A-ASSOCIATE confirmation (accept).
  ae3,

  /// Issue an A-ASSOCIATE confirmation (reject) and close the transport.
  ae4,

  /// Issue a transport connection response and start ARTIM (acceptor).
  ae5,

  /// Stop ARTIM; issue an A-ASSOCIATE indication, or send A-ASSOCIATE-RJ.
  ae6,

  /// Send A-ASSOCIATE-AC.
  ae7,

  /// Send A-ASSOCIATE-RJ and start ARTIM.
  ae8,

  /// Send P-DATA-TF.
  dt1,

  /// Issue a P-DATA indication.
  dt2,

  /// Send A-RELEASE-RQ.
  ar1,

  /// Issue an A-RELEASE indication.
  ar2,

  /// Issue an A-RELEASE confirmation and close the transport.
  ar3,

  /// Send A-RELEASE-RP and start ARTIM.
  ar4,

  /// Stop ARTIM (the transport has closed).
  ar5,

  /// Issue a P-DATA indication while awaiting A-RELEASE-RP.
  ar6,

  /// Send P-DATA-TF while awaiting the local release response.
  ar7,

  /// Issue an A-RELEASE indication (release collision).
  ar8,

  /// Send A-RELEASE-RP (release collision).
  ar9,

  /// Issue an A-RELEASE confirmation (release collision).
  ar10,

  /// Send A-ABORT (service user) and start ARTIM.
  aa1,

  /// Stop ARTIM and close the transport.
  aa2,

  /// Issue an A-ABORT indication and close the transport.
  aa3,

  /// Issue an A-P-ABORT indication (the transport closed).
  aa4,

  /// Stop ARTIM (the transport closed before A-ASSOCIATE-RQ).
  aa5,

  /// Ignore the PDU.
  aa6,

  /// Send A-ABORT.
  aa7,

  /// Send A-ABORT (service provider), issue an A-P-ABORT indication, and
  /// start ARTIM.
  aa8,
}

/// A transition: the action to perform and the state that follows it.
typedef Transition = (UlAction, UlState);

/// Every transition PS3.8 Table 9-10 defines: 123 of the 247 (state,
/// event) cells. The rest are blank: an event the standard gives no meaning
/// in that state. Transcribed from pynetdicom's table, which
/// `fsm_test.dart` checks cell by cell (I-13).
///
/// Two actions choose their next state when they run, and the state given
/// here is the usual one:
/// - AE-6 goes to Sta3 here. It goes to Sta13 only when the request is
///   unacceptable at the protocol level; dartdicom rejects through the local
///   response instead (AE-8).
/// - AR-8 goes to Sta9 for the requestor and to Sta10 for the acceptor; the
///   DUL picks.
const Map<(UlState, UlEvent), Transition> transitions = {
  // Sta1: Idle.
  (UlState.sta1, UlEvent.evt1): (UlAction.ae1, UlState.sta4),
  (UlState.sta1, UlEvent.evt5): (UlAction.ae5, UlState.sta2),
  // Sta2: Awaiting A-ASSOCIATE-RQ (acceptor).
  (UlState.sta2, UlEvent.evt3): (UlAction.aa1, UlState.sta13),
  (UlState.sta2, UlEvent.evt4): (UlAction.aa1, UlState.sta13),
  (UlState.sta2, UlEvent.evt6): (UlAction.ae6, UlState.sta3),
  (UlState.sta2, UlEvent.evt10): (UlAction.aa1, UlState.sta13),
  (UlState.sta2, UlEvent.evt12): (UlAction.aa1, UlState.sta13),
  (UlState.sta2, UlEvent.evt13): (UlAction.aa1, UlState.sta13),
  (UlState.sta2, UlEvent.evt16): (UlAction.aa2, UlState.sta1),
  (UlState.sta2, UlEvent.evt17): (UlAction.aa5, UlState.sta1),
  (UlState.sta2, UlEvent.evt18): (UlAction.aa2, UlState.sta1),
  (UlState.sta2, UlEvent.evt19): (UlAction.aa1, UlState.sta13),
  // Sta3: Awaiting the local A-ASSOCIATE response (acceptor).
  (UlState.sta3, UlEvent.evt3): (UlAction.aa8, UlState.sta13),
  (UlState.sta3, UlEvent.evt4): (UlAction.aa8, UlState.sta13),
  (UlState.sta3, UlEvent.evt6): (UlAction.aa8, UlState.sta13),
  (UlState.sta3, UlEvent.evt7): (UlAction.ae7, UlState.sta6),
  (UlState.sta3, UlEvent.evt8): (UlAction.ae8, UlState.sta13),
  (UlState.sta3, UlEvent.evt10): (UlAction.aa8, UlState.sta13),
  (UlState.sta3, UlEvent.evt12): (UlAction.aa8, UlState.sta13),
  (UlState.sta3, UlEvent.evt13): (UlAction.aa8, UlState.sta13),
  (UlState.sta3, UlEvent.evt15): (UlAction.aa1, UlState.sta13),
  (UlState.sta3, UlEvent.evt16): (UlAction.aa3, UlState.sta1),
  (UlState.sta3, UlEvent.evt17): (UlAction.aa4, UlState.sta1),
  (UlState.sta3, UlEvent.evt19): (UlAction.aa8, UlState.sta13),
  // Sta4: Awaiting the transport connection (requestor).
  (UlState.sta4, UlEvent.evt2): (UlAction.ae2, UlState.sta5),
  (UlState.sta4, UlEvent.evt15): (UlAction.aa2, UlState.sta1),
  (UlState.sta4, UlEvent.evt17): (UlAction.aa4, UlState.sta1),
  // Sta5: Awaiting A-ASSOCIATE-AC or -RJ (requestor).
  (UlState.sta5, UlEvent.evt3): (UlAction.ae3, UlState.sta6),
  (UlState.sta5, UlEvent.evt4): (UlAction.ae4, UlState.sta1),
  (UlState.sta5, UlEvent.evt6): (UlAction.aa8, UlState.sta13),
  (UlState.sta5, UlEvent.evt10): (UlAction.aa8, UlState.sta13),
  (UlState.sta5, UlEvent.evt12): (UlAction.aa8, UlState.sta13),
  (UlState.sta5, UlEvent.evt13): (UlAction.aa8, UlState.sta13),
  (UlState.sta5, UlEvent.evt15): (UlAction.aa1, UlState.sta13),
  (UlState.sta5, UlEvent.evt16): (UlAction.aa3, UlState.sta1),
  (UlState.sta5, UlEvent.evt17): (UlAction.aa4, UlState.sta1),
  (UlState.sta5, UlEvent.evt19): (UlAction.aa8, UlState.sta13),
  // Sta6: Established.
  (UlState.sta6, UlEvent.evt3): (UlAction.aa8, UlState.sta13),
  (UlState.sta6, UlEvent.evt4): (UlAction.aa8, UlState.sta13),
  (UlState.sta6, UlEvent.evt6): (UlAction.aa8, UlState.sta13),
  (UlState.sta6, UlEvent.evt9): (UlAction.dt1, UlState.sta6),
  (UlState.sta6, UlEvent.evt10): (UlAction.dt2, UlState.sta6),
  (UlState.sta6, UlEvent.evt11): (UlAction.ar1, UlState.sta7),
  (UlState.sta6, UlEvent.evt12): (UlAction.ar2, UlState.sta8),
  (UlState.sta6, UlEvent.evt13): (UlAction.aa8, UlState.sta13),
  (UlState.sta6, UlEvent.evt15): (UlAction.aa1, UlState.sta13),
  (UlState.sta6, UlEvent.evt16): (UlAction.aa3, UlState.sta1),
  (UlState.sta6, UlEvent.evt17): (UlAction.aa4, UlState.sta1),
  (UlState.sta6, UlEvent.evt19): (UlAction.aa8, UlState.sta13),
  // Sta7: Awaiting A-RELEASE-RP.
  (UlState.sta7, UlEvent.evt3): (UlAction.aa8, UlState.sta13),
  (UlState.sta7, UlEvent.evt4): (UlAction.aa8, UlState.sta13),
  (UlState.sta7, UlEvent.evt6): (UlAction.aa8, UlState.sta13),
  (UlState.sta7, UlEvent.evt10): (UlAction.ar6, UlState.sta7),
  (UlState.sta7, UlEvent.evt12): (UlAction.ar8, UlState.sta9),
  (UlState.sta7, UlEvent.evt13): (UlAction.ar3, UlState.sta1),
  (UlState.sta7, UlEvent.evt15): (UlAction.aa1, UlState.sta13),
  (UlState.sta7, UlEvent.evt16): (UlAction.aa3, UlState.sta1),
  (UlState.sta7, UlEvent.evt17): (UlAction.aa4, UlState.sta1),
  (UlState.sta7, UlEvent.evt19): (UlAction.aa8, UlState.sta13),
  // Sta8: Awaiting the local A-RELEASE response.
  (UlState.sta8, UlEvent.evt3): (UlAction.aa8, UlState.sta13),
  (UlState.sta8, UlEvent.evt4): (UlAction.aa8, UlState.sta13),
  (UlState.sta8, UlEvent.evt6): (UlAction.aa8, UlState.sta13),
  (UlState.sta8, UlEvent.evt9): (UlAction.ar7, UlState.sta8),
  (UlState.sta8, UlEvent.evt10): (UlAction.aa8, UlState.sta13),
  (UlState.sta8, UlEvent.evt12): (UlAction.aa8, UlState.sta13),
  (UlState.sta8, UlEvent.evt13): (UlAction.aa8, UlState.sta13),
  (UlState.sta8, UlEvent.evt14): (UlAction.ar4, UlState.sta13),
  (UlState.sta8, UlEvent.evt15): (UlAction.aa1, UlState.sta13),
  (UlState.sta8, UlEvent.evt16): (UlAction.aa3, UlState.sta1),
  (UlState.sta8, UlEvent.evt17): (UlAction.aa4, UlState.sta1),
  (UlState.sta8, UlEvent.evt19): (UlAction.aa8, UlState.sta13),
  // Sta9: Release collision, requestor: awaiting the local response.
  (UlState.sta9, UlEvent.evt3): (UlAction.aa8, UlState.sta13),
  (UlState.sta9, UlEvent.evt4): (UlAction.aa8, UlState.sta13),
  (UlState.sta9, UlEvent.evt6): (UlAction.aa8, UlState.sta13),
  (UlState.sta9, UlEvent.evt10): (UlAction.aa8, UlState.sta13),
  (UlState.sta9, UlEvent.evt12): (UlAction.aa8, UlState.sta13),
  (UlState.sta9, UlEvent.evt13): (UlAction.aa8, UlState.sta13),
  (UlState.sta9, UlEvent.evt14): (UlAction.ar9, UlState.sta11),
  (UlState.sta9, UlEvent.evt15): (UlAction.aa1, UlState.sta13),
  (UlState.sta9, UlEvent.evt16): (UlAction.aa3, UlState.sta1),
  (UlState.sta9, UlEvent.evt17): (UlAction.aa4, UlState.sta1),
  (UlState.sta9, UlEvent.evt19): (UlAction.aa8, UlState.sta13),
  // Sta10: Release collision, acceptor: awaiting A-RELEASE-RP.
  (UlState.sta10, UlEvent.evt3): (UlAction.aa8, UlState.sta13),
  (UlState.sta10, UlEvent.evt4): (UlAction.aa8, UlState.sta13),
  (UlState.sta10, UlEvent.evt6): (UlAction.aa8, UlState.sta13),
  (UlState.sta10, UlEvent.evt10): (UlAction.aa8, UlState.sta13),
  (UlState.sta10, UlEvent.evt12): (UlAction.aa8, UlState.sta13),
  (UlState.sta10, UlEvent.evt13): (UlAction.ar10, UlState.sta12),
  (UlState.sta10, UlEvent.evt15): (UlAction.aa1, UlState.sta13),
  (UlState.sta10, UlEvent.evt16): (UlAction.aa3, UlState.sta1),
  (UlState.sta10, UlEvent.evt17): (UlAction.aa4, UlState.sta1),
  (UlState.sta10, UlEvent.evt19): (UlAction.aa8, UlState.sta13),
  // Sta11: Release collision, requestor: awaiting A-RELEASE-RP.
  (UlState.sta11, UlEvent.evt3): (UlAction.aa8, UlState.sta13),
  (UlState.sta11, UlEvent.evt4): (UlAction.aa8, UlState.sta13),
  (UlState.sta11, UlEvent.evt6): (UlAction.aa8, UlState.sta13),
  (UlState.sta11, UlEvent.evt10): (UlAction.aa8, UlState.sta13),
  (UlState.sta11, UlEvent.evt12): (UlAction.aa8, UlState.sta13),
  (UlState.sta11, UlEvent.evt13): (UlAction.ar3, UlState.sta1),
  (UlState.sta11, UlEvent.evt15): (UlAction.aa1, UlState.sta13),
  (UlState.sta11, UlEvent.evt16): (UlAction.aa3, UlState.sta1),
  (UlState.sta11, UlEvent.evt17): (UlAction.aa4, UlState.sta1),
  (UlState.sta11, UlEvent.evt19): (UlAction.aa8, UlState.sta13),
  // Sta12: Release collision, acceptor: awaiting the local response.
  (UlState.sta12, UlEvent.evt3): (UlAction.aa8, UlState.sta13),
  (UlState.sta12, UlEvent.evt4): (UlAction.aa8, UlState.sta13),
  (UlState.sta12, UlEvent.evt6): (UlAction.aa8, UlState.sta13),
  (UlState.sta12, UlEvent.evt10): (UlAction.aa8, UlState.sta13),
  (UlState.sta12, UlEvent.evt12): (UlAction.aa8, UlState.sta13),
  (UlState.sta12, UlEvent.evt13): (UlAction.aa8, UlState.sta13),
  (UlState.sta12, UlEvent.evt14): (UlAction.ar4, UlState.sta13),
  (UlState.sta12, UlEvent.evt15): (UlAction.aa1, UlState.sta13),
  (UlState.sta12, UlEvent.evt16): (UlAction.aa3, UlState.sta1),
  (UlState.sta12, UlEvent.evt17): (UlAction.aa4, UlState.sta1),
  (UlState.sta12, UlEvent.evt19): (UlAction.aa8, UlState.sta13),
  // Sta13: Awaiting the transport to close.
  (UlState.sta13, UlEvent.evt3): (UlAction.aa6, UlState.sta13),
  (UlState.sta13, UlEvent.evt4): (UlAction.aa6, UlState.sta13),
  (UlState.sta13, UlEvent.evt6): (UlAction.aa7, UlState.sta13),
  (UlState.sta13, UlEvent.evt10): (UlAction.aa6, UlState.sta13),
  (UlState.sta13, UlEvent.evt12): (UlAction.aa6, UlState.sta13),
  (UlState.sta13, UlEvent.evt13): (UlAction.aa6, UlState.sta13),
  (UlState.sta13, UlEvent.evt16): (UlAction.aa2, UlState.sta1),
  (UlState.sta13, UlEvent.evt17): (UlAction.ar5, UlState.sta1),
  (UlState.sta13, UlEvent.evt18): (UlAction.aa2, UlState.sta1),
  (UlState.sta13, UlEvent.evt19): (UlAction.aa7, UlState.sta13),
};

/// The transition for [event] in [state], or `null` for a blank cell.
Transition? transition(UlState state, UlEvent event) =>
    transitions[(state, event)];

/// [event] in [from] in PS3.8's names, as the trace shows it: with the
/// transition [to] it took, `Sta6 + Evt10 → DT-2 → Sta6`; without one,
/// `Sta6 + Evt3: blank`.
String describeTransition(UlState from, UlEvent event, [Transition? to]) =>
    '${_name(from)} + ${_name(event)}'
    '${to == null ? ': blank' : ' → ${_name(to.$1)} → ${_name(to.$2)}'}';

/// `sta6` → `Sta6`, `evt10` → `Evt10`, `dt2` → `DT-2`.
String _name(Enum e) => switch (e) {
      UlAction() =>
        '${e.name.substring(0, 2).toUpperCase()}-${e.name.substring(2)}',
      _ => '${e.name[0].toUpperCase()}${e.name.substring(1)}',
    };
