part of 'pdu.dart';

/// A-RELEASE-RQ (type 0x05).
final class ReleaseRq extends Pdu {
  const ReleaseRq();

  @override
  String get summary => 'A-RELEASE-RQ';

  @override
  int get type => 0x05;

  @override
  void encodeBody(PduWriter w) => w.zeros(4);

  @override
  String toString() => 'A-RELEASE-RQ';
}

/// A-RELEASE-RP (type 0x06).
final class ReleaseRp extends Pdu {
  const ReleaseRp();

  @override
  String get summary => 'A-RELEASE-RP';

  @override
  int get type => 0x06;

  @override
  void encodeBody(PduWriter w) => w.zeros(4);

  @override
  String toString() => 'A-RELEASE-RP';
}

/// A-ABORT (type 0x07).
final class Abort extends Pdu {
  const Abort({this.source = 0, this.reason = 0});

  /// 0 service user, 2 service provider.
  final int source;

  /// For a provider abort (PS3.8 Table 9-26): 0 not specified, 1 unrecognized
  /// PDU, 2 unexpected PDU, 4 unrecognized parameter, 5 unexpected parameter,
  /// 6 invalid parameter value.
  final int reason;

  @override
  String get summary => 'A-ABORT source $source, reason $reason';

  @override
  int get type => 0x07;

  @override
  void encodeBody(PduWriter w) => w
    ..zeros(2)
    ..u8(source)
    ..u8(reason);

  static Abort _decode(PduReader r) {
    r.skip(2);
    return Abort(source: r.u8(), reason: r.u8());
  }

  @override
  String toString() => 'A-ABORT($source, $reason)';
}
