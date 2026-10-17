// The DICOM Upper Layer state machine (PS3.8 §9.2, Table 9-10) as data:
// (state, event) → (action, next state). It holds no I/O; the DUL performs
// the actions. M1 fills the requestor's rows; M3 completes the table to all
// 19 × 13 pairs (I-13) without changing these types.

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

/// The transitions defined so far.
const Map<(UlState, UlEvent), Transition> transitions = {
  // Association establishment, requestor side.
  (UlState.sta1, UlEvent.evt1): (UlAction.ae1, UlState.sta4),
  (UlState.sta4, UlEvent.evt2): (UlAction.ae2, UlState.sta5),
  (UlState.sta4, UlEvent.evt15): (UlAction.aa2, UlState.sta1),
  (UlState.sta4, UlEvent.evt17): (UlAction.aa4, UlState.sta1),
  (UlState.sta5, UlEvent.evt3): (UlAction.ae3, UlState.sta6),
  (UlState.sta5, UlEvent.evt4): (UlAction.ae4, UlState.sta1),
  (UlState.sta5, UlEvent.evt15): (UlAction.aa1, UlState.sta13),
  (UlState.sta5, UlEvent.evt16): (UlAction.aa3, UlState.sta1),
  (UlState.sta5, UlEvent.evt17): (UlAction.aa4, UlState.sta1),
  (UlState.sta5, UlEvent.evt19): (UlAction.aa8, UlState.sta13),
  // Data transfer.
  (UlState.sta6, UlEvent.evt9): (UlAction.dt1, UlState.sta6),
  (UlState.sta6, UlEvent.evt10): (UlAction.dt2, UlState.sta6),
  (UlState.sta6, UlEvent.evt11): (UlAction.ar1, UlState.sta7),
  (UlState.sta6, UlEvent.evt15): (UlAction.aa1, UlState.sta13),
  (UlState.sta6, UlEvent.evt16): (UlAction.aa3, UlState.sta1),
  (UlState.sta6, UlEvent.evt17): (UlAction.aa4, UlState.sta1),
  (UlState.sta6, UlEvent.evt19): (UlAction.aa8, UlState.sta13),
  // Release, requestor side.
  (UlState.sta7, UlEvent.evt10): (UlAction.ar6, UlState.sta7),
  (UlState.sta7, UlEvent.evt13): (UlAction.ar3, UlState.sta1),
  (UlState.sta7, UlEvent.evt15): (UlAction.aa1, UlState.sta13),
  (UlState.sta7, UlEvent.evt16): (UlAction.aa3, UlState.sta1),
  (UlState.sta7, UlEvent.evt17): (UlAction.aa4, UlState.sta1),
  (UlState.sta7, UlEvent.evt19): (UlAction.aa8, UlState.sta13),
  // Awaiting the transport to close.
  (UlState.sta13, UlEvent.evt3): (UlAction.aa6, UlState.sta13),
  (UlState.sta13, UlEvent.evt4): (UlAction.aa6, UlState.sta13),
  (UlState.sta13, UlEvent.evt10): (UlAction.aa6, UlState.sta13),
  (UlState.sta13, UlEvent.evt12): (UlAction.aa6, UlState.sta13),
  (UlState.sta13, UlEvent.evt13): (UlAction.aa6, UlState.sta13),
  (UlState.sta13, UlEvent.evt16): (UlAction.aa2, UlState.sta1),
  (UlState.sta13, UlEvent.evt17): (UlAction.ar5, UlState.sta1),
  (UlState.sta13, UlEvent.evt19): (UlAction.aa6, UlState.sta13),
};

/// The transition for a *received* [event] (a PDU, the transport closing)
/// in [state]. A PDU that arrives where the table defines nothing is an
/// unexpected PDU: AA-8, as PS3.8 specifies for the established and
/// awaiting states. Local requests look up [transitions] directly: one the
/// table doesn't define is a programming error, not a peer's.
Transition transition(UlState state, UlEvent event) =>
    transitions[(state, event)] ?? (UlAction.aa8, UlState.sta13);
