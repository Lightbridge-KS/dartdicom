part of 'pdu.dart';

/// A-ASSOCIATE-RQ (type 0x01).
final class AssociateRq extends Pdu {
  const AssociateRq({
    required this.calledAeTitle,
    required this.callingAeTitle,
    required this.contexts,
    required this.userInformation,
    this.applicationContext = dicomApplicationContext,
  });

  final String calledAeTitle;
  final String callingAeTitle;
  final String applicationContext;
  final List<ProposedContext> contexts;
  final UserInformation userInformation;

  @override
  String get summary => 'A-ASSOCIATE-RQ $callingAeTitle → $calledAeTitle, '
      '${contexts.length} context${contexts.length == 1 ? '' : 's'}, '
      '${userInformation.roles.length} role item'
      '${userInformation.roles.length == 1 ? '' : 's'}, '
      'max PDU ${userInformation.maxLength}';

  @override
  int get type => 0x01;

  @override
  void encodeBody(PduWriter w) {
    _encodeHeader(w, calledAeTitle, callingAeTitle, applicationContext);
    for (final c in contexts) {
      c.encode(w);
    }
    userInformation.encode(w);
  }

  static AssociateRq _decode(PduReader r) {
    final (called, calling) = _decodeHeader(r);
    var appContext = '';
    final contexts = <ProposedContext>[];
    UserInformation? userInfo;
    r.items(r.end, (type, end) {
      switch (type) {
        case ItemType.applicationContext:
          appContext = r.text(end - r.at);
        case ItemType.presentationContextRq:
          contexts.add(ProposedContext.decode(r, end));
        case ItemType.userInformation:
          userInfo = UserInformation.decode(r, end);
      }
    });
    return AssociateRq(
        calledAeTitle: called,
        callingAeTitle: calling,
        applicationContext: appContext,
        contexts: contexts,
        userInformation: userInfo ??
            (throw const FormatException(
                'A-ASSOCIATE-RQ has no User Information')));
  }

  @override
  String toString() => 'A-ASSOCIATE-RQ($callingAeTitle → $calledAeTitle, '
      '${contexts.length} contexts)';
}

/// A-ASSOCIATE-AC (type 0x02).
final class AssociateAc extends Pdu {
  const AssociateAc({
    required this.calledAeTitle,
    required this.callingAeTitle,
    required this.results,
    required this.userInformation,
    this.applicationContext = dicomApplicationContext,
  });

  final String calledAeTitle;
  final String callingAeTitle;
  final String applicationContext;
  final List<ContextResult> results;
  final UserInformation userInformation;

  @override
  String get summary => 'A-ASSOCIATE-AC '
      '${results.where((r) => r.accepted).length} of ${results.length} '
      'context${results.length == 1 ? '' : 's'} accepted, '
      'max PDU ${userInformation.maxLength}';

  @override
  int get type => 0x02;

  @override
  void encodeBody(PduWriter w) {
    _encodeHeader(w, calledAeTitle, callingAeTitle, applicationContext);
    for (final c in results) {
      c.encode(w);
    }
    userInformation.encode(w);
  }

  static AssociateAc _decode(PduReader r) {
    final (called, calling) = _decodeHeader(r);
    var appContext = '';
    final results = <ContextResult>[];
    UserInformation? userInfo;
    r.items(r.end, (type, end) {
      switch (type) {
        case ItemType.applicationContext:
          appContext = r.text(end - r.at);
        case ItemType.presentationContextAc:
          results.add(ContextResult.decode(r, end));
        case ItemType.userInformation:
          userInfo = UserInformation.decode(r, end);
      }
    });
    return AssociateAc(
        calledAeTitle: called,
        callingAeTitle: calling,
        applicationContext: appContext,
        results: results,
        userInformation: userInfo ??
            (throw const FormatException(
                'A-ASSOCIATE-AC has no User Information')));
  }

  @override
  String toString() =>
      'A-ASSOCIATE-AC(${results.where((c) => c.accepted).length} of '
      '${results.length} contexts accepted)';
}

/// A-ASSOCIATE-RJ (type 0x03).
final class AssociateRj extends Pdu {
  const AssociateRj(
      {required this.result, required this.source, required this.reason});

  /// 1 rejected permanently, 2 rejected transiently.
  final int result;

  /// 1 service user, 2 service provider (ACSE), 3 service provider
  /// (presentation).
  final int source;

  /// What was wrong, by [source] (PS3.8 Table 9-21).
  final int reason;

  @override
  String get summary =>
      'A-ASSOCIATE-RJ result $result, source $source, reason $reason';

  @override
  int get type => 0x03;

  @override
  void encodeBody(PduWriter w) => w
    ..u8(0)
    ..u8(result)
    ..u8(source)
    ..u8(reason);

  static AssociateRj _decode(PduReader r) {
    r.skip(1);
    return AssociateRj(result: r.u8(), source: r.u8(), reason: r.u8());
  }

  @override
  String toString() => 'A-ASSOCIATE-RJ($result, $source, $reason)';
}

void _encodeHeader(
    PduWriter w, String called, String calling, String appContext) {
  w
    ..u16(0x0001) // protocol version
    ..zeros(2)
    ..aeTitle(called)
    ..aeTitle(calling)
    ..zeros(32)
    ..item(ItemType.applicationContext, (s) => s.ascii(appContext));
}

(String, String) _decodeHeader(PduReader r) {
  r.skip(4); // protocol version, reserved
  final called = r.text(16);
  final calling = r.text(16);
  r.skip(32);
  return (called, calling);
}
