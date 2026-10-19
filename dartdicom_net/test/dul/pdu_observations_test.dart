// Characterization through Dul: these tests also pass before projection moves.
import 'dart:convert';
import 'dart:math';

import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dul/dul.dart';
import 'package:dartdicom_net/src/pdu/items.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:dartdicom_net/src/trace/observations.dart'
    show ObservationRecorder;
import 'package:test/test.dart';

import '../support/peer.dart';

const _rq = AssociateRq(
    calledAeTitle: 'SCP',
    callingAeTitle: 'SCU',
    contexts: [
      ProposedContext(1, '1.2.3', ['1.2.4', '1.2.5']),
      ProposedContext(3, '1.2.6', ['1.2.4']),
      ProposedContext(5, '1.2.7', ['1.2.4']),
    ],
    userInformation:
        UserInformation(maxLength: 16384, implementationClassUid: '1.2.8'));

final class _Recorder implements AssociationObserver {
  final events = <AssociationObservation>[];
  @override
  void record(AssociationObservation event) => events.add(event);
}

Future<List<AssociationObservation>> _observe(AssociateAc ac,
    {AssociateRq rq = _rq, void Function()? afterRequest}) async {
  final (transport, peer) = ScriptedPeer.connect();
  final recorder = _Recorder();
  final dul = Dul.requestor(transport,
      observations: ObservationRecorder(recorder, 'projection'));
  final answer = dul.requestAssociation(rq);
  await peer.next();
  afterRequest?.call();
  await peer.send(ac);
  await answer;
  dul.forceClose();
  await dul.closed;
  return recorder.events;
}

AssociateAc _ac(List<ContextResult> results, UserInformation userInformation) =>
    AssociateAc(
        calledAeTitle: 'SCP',
        callingAeTitle: 'SCU',
        results: results,
        userInformation: userInformation);

Map<String, Object?> _context(ContextObservation c) => {
      'id': c.id,
      'abstractSyntax': c.abstractSyntax,
      'proposedTransferSyntaxes': c.proposedTransferSyntaxes,
      'result': c.result,
      'selectedTransferSyntax': c.selectedTransferSyntax,
      'scuRole': c.scuRole,
      'scpRole': c.scpRole,
    };

// Compare every observation field except wall-clock-dependent elapsed time.
Map<String, Object?> _event(AssociationObservation e) => {
      'associationId': e.associationId,
      'sequence': e.sequence,
      'kind': e.kind.name,
      'direction': e.direction.name,
      'contexts': e.contexts.map(_context).toList(),
      'result': e.result,
      'source': e.source,
      'reason': e.reason,
      'commandField': e.commandField,
      'messageId': e.messageId,
      'responseTo': e.responseTo,
      'status': e.status,
      'contextId': e.contextId,
      'peerMaxPduLength': e.peerMaxPduLength,
      'timeoutKind': e.timeoutKind?.name,
      'peerImplementationClassUid': e.peerImplementationClassUid,
      'maxInvoked': e.maxInvoked,
      'maxPerformed': e.maxPerformed,
    };

void main() {
  test('contexts keep proposal order, first matches, and unmatched results',
      () async {
    final events = await _observe(_ac(
        const [
          ContextResult(5, 3, '1.2.4'),
          ContextResult(1, 4, '1.2.4'),
          ContextResult(1, 0, '1.2.5'),
          ContextResult(9, 0, '1.2.9'),
        ],
        const UserInformation(
            maxLength: 32768,
            implementationClassUid: '1.2.8',
            roles: [
              RoleSelection('1.2.3', scu: true, scp: false),
              RoleSelection('1.2.3', scu: false, scp: true),
            ],
            asyncWindow: AsyncOperationsWindow(invoked: 2, performed: 0))));
    final ac = events[1];
    expect(ac.contexts.map((c) => c.id), [1, 3, 5, 9]);
    expect(_context(ac.contexts.first), {
      'id': 1,
      'abstractSyntax': '1.2.3',
      'proposedTransferSyntaxes': ['1.2.4', '1.2.5'],
      'result': 4,
      'selectedTransferSyntax': '1.2.5',
      'scuRole': true,
      'scpRole': false,
    });
    expect(ac.contexts[1].result, isNull);
    expect(ac.contexts[1].scuRole, isNull);
    expect(ac.contexts[2].selectedTransferSyntax, isNull);
    expect(ac.contexts.last.abstractSyntax, '');
    expect(ac.contexts.last.proposedTransferSyntaxes, isEmpty);
    expect(ac.contexts.last.selectedTransferSyntax, '1.2.9');
    expect(
        (ac.peerMaxPduLength, ac.maxInvoked, ac.maxPerformed), (32768, 2, 0));
  });

  test('proposal snapshots survive caller mutation and remain immutable',
      () async {
    final syntaxes = ['1.2.4'];
    final contexts = [ProposedContext(1, '1.2.3', syntaxes)];
    final events = await _observe(
        _ac(const [ContextResult(1, 0, '1.2.4')], _rq.userInformation),
        rq: AssociateRq(
            calledAeTitle: 'SCP',
            callingAeTitle: 'SCU',
            contexts: contexts,
            userInformation: _rq.userInformation), afterRequest: () {
      syntaxes.clear();
      contexts.clear();
    });
    for (final event in events.take(2)) {
      expect(event.contexts.single.proposedTransferSyntaxes, ['1.2.4']);
      expect(() => event.contexts.clear(), throwsUnsupportedError);
      expect(() => event.contexts.single.proposedTransferSyntaxes.clear(),
          throwsUnsupportedError);
    }
  });

  for (final uid in [
    '1.2.3',
    'PRIVATE_CANARY',
    '1.${'2' * 62}',
    '1.${'2' * 63}'
  ]) {
    test('peer implementation UID filtering: length=${uid.length}, uid=$uid',
        () async {
      final events = await _observe(_ac(const [],
          UserInformation(maxLength: 0, implementationClassUid: uid)));
      expect(events[1].peerImplementationClassUid,
          uid.startsWith('1.') && uid.length <= 64 ? uid : null);
    });
  }

  test('seeded negotiation transcripts preserve all fields and event ordering',
      () async {
    final random = Random(42);
    final transcripts = <Object>[];
    for (var i = 0; i < 32; i++) {
      final present = i.isEven;
      final events = await _observe(_ac(
          [
            for (final id in [5, 1, 9])
              ContextResult(id, random.nextInt(5), '1.2.${random.nextInt(9)}'),
          ],
          UserInformation(
              maxLength: i % 3 == 0 ? 0 : 16384,
              hasMaxLength: present,
              implementationClassUid: i % 3 == 0 ? 'PRIVATE_CANARY' : '1.2.8',
              roles: i % 3 == 0
                  ? const []
                  : [RoleSelection('1.2.3', scu: i.isEven, scp: i.isOdd)],
              asyncWindow: i % 3 == 0
                  ? null
                  : AsyncOperationsWindow(invoked: i, performed: 0))));
      expect(events.map((e) => (e.kind, e.direction)), [
        (ObservationKind.associateRequest, ObservationDirection.outgoing),
        (ObservationKind.associateAccept, ObservationDirection.incoming),
        (ObservationKind.transportClosed, ObservationDirection.local),
      ]);
      expect(events.map((e) => e.sequence), [1, 2, 3]);
      for (var n = 1; n < events.length; n++) {
        expect(events[n].elapsed, greaterThanOrEqualTo(events[n - 1].elapsed));
      }
      expect(events[1].peerMaxPduLength,
          present ? (i % 3 == 0 ? 0 : 16384) : null);
      transcripts.add(events.map(_event).toList());
    }
    print('projection transcripts: ${jsonEncode(transcripts)}');
  });
}
