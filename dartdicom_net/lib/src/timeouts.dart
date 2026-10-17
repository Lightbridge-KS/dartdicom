/// How long an association waits before it gives up (PRD N-13), with
/// pynetdicom's defaults. Expiry aborts the association and throws a
/// `DimseTimeout` that names the timer.
final class Timeouts {
  const Timeouts({
    this.connect = const Duration(seconds: 30),
    this.acse = const Duration(seconds: 30),
    this.dimse = const Duration(seconds: 30),
    this.network = const Duration(seconds: 60),
  });

  /// The TCP connect.
  final Duration connect;

  /// Waiting for A-ASSOCIATE-AC/RJ and for A-RELEASE-RP. Also the ARTIM
  /// timer: an acceptor waiting for the A-ASSOCIATE-RQ, and either side
  /// waiting for the peer to close the connection.
  final Duration acse;

  /// Each wait for the peer's next PDU during an operation. A long C-MOVE
  /// that keeps sending pending responses never trips it.
  final Duration dimse;

  /// An established association that runs no operation and receives
  /// nothing (or, for an acceptor, waits for the next request).
  final Duration network;
}

/// Which of the [Timeouts] expired.
enum TimeoutKind {
  connect('connect', 'could not connect'),
  acse('acse', 'the peer did not answer the association request or release'),
  dimse('dimse', 'the peer sent nothing during the operation'),
  network('network', 'the association was idle');

  const TimeoutKind(this.setting, this.what);

  /// The [Timeouts] field to raise.
  final String setting;

  /// What happened, in a phrase.
  final String what;
}
