import 'dart:typed_data';

import 'bytes.dart';
import 'items.dart';

/// A Protocol Data Unit of the DICOM Upper Layer (PS3.8 §9.3): one of
/// seven, each `type | reserved | length (4 bytes, big-endian) | body`.
sealed class Pdu {
  const Pdu();

  /// The PDU type byte.
  int get type;

  /// The whole PDU: the 6-byte header and the body.
  Uint8List encode() {
    final body = PduWriter();
    encodeBody(body);
    final out = PduWriter()
      ..u8(type)
      ..u8(0)
      ..u32(body.length)
      ..bytes(body.take());
    return out.take();
  }

  void encodeBody(PduWriter w);

  /// Decodes one whole PDU. Throws a [FormatException] if it is malformed
  /// or of an unknown type: the DUL's invalid-PDU event (Evt19).
  static Pdu decode(Uint8List pdu) {
    final r = PduReader(pdu);
    final type = r.u8();
    r.skip(1);
    final length = r.u32();
    if (6 + length != pdu.length) {
      throw const FormatException('PDU length disagrees with its size');
    }
    return switch (type) {
      0x01 => AssociateRq._decode(r),
      0x02 => AssociateAc._decode(r),
      0x03 => AssociateRj._decode(r),
      0x04 => PDataTf._decode(r),
      0x05 => const ReleaseRq(),
      0x06 => const ReleaseRp(),
      0x07 => Abort._decode(r),
      _ =>
        throw FormatException('unknown PDU type 0x${type.toRadixString(16)}'),
    };
  }
}

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

/// One Presentation Data Value: a fragment of a command or a dataset.
final class Pdv {
  const Pdv(this.contextId, this.data,
      {required this.isCommand, required this.isLast});

  final int contextId;
  final Uint8List data;

  /// Bit 0 of the control header: a command (1) or a dataset (0) fragment.
  final bool isCommand;

  /// Bit 1 of the control header: the last fragment of its message part.
  final bool isLast;
}

/// P-DATA-TF (type 0x04): one or more PDVs.
final class PDataTf extends Pdu {
  const PDataTf(this.pdvs);

  final List<Pdv> pdvs;

  @override
  int get type => 0x04;

  @override
  void encodeBody(PduWriter w) {
    for (final pdv in pdvs) {
      w
        ..u32(pdv.data.length + 2)
        ..u8(pdv.contextId)
        ..u8((pdv.isCommand ? 1 : 0) | (pdv.isLast ? 2 : 0))
        ..bytes(pdv.data);
    }
  }

  static PDataTf _decode(PduReader r) {
    final pdvs = <Pdv>[];
    while (!r.done) {
      final length = r.u32();
      if (length < 2) {
        throw const FormatException('a PDV is shorter than 2 bytes');
      }
      final contextId = r.u8();
      final header = r.u8();
      pdvs.add(Pdv(contextId, r.take(length - 2),
          isCommand: header & 1 != 0, isLast: header & 2 != 0));
    }
    return PDataTf(pdvs);
  }

  @override
  String toString() => 'P-DATA-TF(${pdvs.length} PDVs)';
}

/// A-RELEASE-RQ (type 0x05).
final class ReleaseRq extends Pdu {
  const ReleaseRq();

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
