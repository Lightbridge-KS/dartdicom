import 'package:dartdicom_net/src/pdu/items.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:dartdicom_net/src/pdu/pdus/pdu.dart' as implementation;
import 'package:test/test.dart';

const _info =
    UserInformation(maxLength: 16384, implementationClassUid: '1.2.3');
const _samples = <Pdu>[
  AssociateRq(
      calledAeTitle: 'SCP',
      callingAeTitle: 'SCU',
      contexts: [
        ProposedContext(1, '1.2.4', ['1.2.5'])
      ],
      userInformation: _info),
  AssociateAc(
      calledAeTitle: 'SCP',
      callingAeTitle: 'SCU',
      results: [ContextResult(1, 0, '1.2.5')],
      userInformation: _info),
  AssociateRj(result: 1, source: 1, reason: 7),
  PDataTf([]),
  ReleaseRq(),
  ReleaseRp(),
  Abort(source: 2, reason: 1),
];

// No fallback: the old import path must retain the closed, seven-type family.
int _kind(Pdu pdu) => switch (pdu) {
      AssociateRq() => 1,
      AssociateAc() => 2,
      AssociateRj() => 3,
      PDataTf() => 4,
      ReleaseRq() => 5,
      ReleaseRp() => 6,
      Abort() => 7,
    };

void main() {
  test('barrel forwards PDU types, constructors, and decoder identity', () {
    for (final pair in <(Object, Object)>[
      (Pdu, implementation.Pdu),
      (AssociateRq, implementation.AssociateRq),
      (AssociateAc, implementation.AssociateAc),
      (AssociateRj, implementation.AssociateRj),
      (PDataTf, implementation.PDataTf),
      (ReleaseRq, implementation.ReleaseRq),
      (ReleaseRp, implementation.ReleaseRp),
      (Abort, implementation.Abort),
      (AssociateRq.new, implementation.AssociateRq.new),
      (AssociateAc.new, implementation.AssociateAc.new),
      (AssociateRj.new, implementation.AssociateRj.new),
      (PDataTf.new, implementation.PDataTf.new),
      (ReleaseRq.new, implementation.ReleaseRq.new),
      (ReleaseRp.new, implementation.ReleaseRp.new),
      (Abort.new, implementation.Abort.new),
      (Pdu.decode, implementation.Pdu.decode),
    ]) {
      expect(identical(pair.$1, pair.$2), isTrue);
    }
  });

  test('barrel supports exhaustive matching and seven const constructors', () {
    for (final pdu in _samples) {
      final decoded = Pdu.decode(pdu.encode());
      expect(_kind(pdu), pdu.type);
      expect(_kind(decoded), pdu.type);
      expect(decoded.runtimeType, pdu.runtimeType);
      expect(decoded.encode(), pdu.encode());
      expect(decoded.summary, pdu.summary);
      expect(decoded.toString(), pdu.toString());
    }
  });
}
