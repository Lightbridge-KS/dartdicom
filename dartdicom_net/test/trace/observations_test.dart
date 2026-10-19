import 'dart:io';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:dartdicom_net/src/pdu/items.dart';
import 'package:test/test.dart';
import '../support/peer.dart';

class Recorder implements AssociationObserver {
  final events = <AssociationObservation>[];
  bool throws = false;
  @override
  void record(AssociationObservation event) {
    events.add(event);
    if (throws) throw StateError('observer defect');
  }
}

void main() {
  test('typed negotiation and DIMSE survive a throwing observer', () async {
    final recorder = Recorder()..throws = true;
    final (transport, peer) = ScriptedPeer.connect();
    final serving = () async {
      await peer.accept(maxLength: 32768);
      final request = await peer.nextMessage();
      await peer.sendMessage(DimseMessage(request.contextId,
          ScriptedPeer.response(CommandField.cEchoRsp, request, 0)));
      await peer.acceptRelease();
    }();
    final ae = ApplicationEntity(
        aeTitle: 'CLIENT',
        requestedContexts: PresentationContexts.verification,
        observer: recorder);
    final association = await ae.associateOver(transport,
        aeTitle: 'PEER', associationId: 'test-1');
    expect(await association.sendCEcho(), isA<DimseSuccess>());
    await association.release();
    await serving;
    final accept = recorder.events
        .singleWhere((e) => e.kind == ObservationKind.associateAccept);
    expect(accept.peerMaxPduLength, 32768);
    expect(accept.contexts.single.result, 0);
    expect(accept.contexts.single.selectedTransferSyntax, isNotNull);
    expect(() => accept.contexts.clear(), throwsUnsupportedError);
    final response =
        recorder.events.singleWhere((e) => e.commandField == 0x8030);
    expect(response.status, 0);
    expect(response.responseTo, 1);
    expect(recorder.events.map((e) => e.sequence),
        orderedEquals(List.generate(recorder.events.length, (i) => i + 1)));
    expect(recorder.events.every((e) => e.associationId == 'test-1'), isTrue);
  });
  test('peer abort preserves numeric fields', () async {
    final (transport, peer) = ScriptedPeer.connect();
    final serving = () async {
      await peer.accept();
      await peer.nextMessage();
      await peer.send(const Abort(source: 2, reason: 2));
    }();
    final a = await const ApplicationEntity(
            aeTitle: 'CLIENT',
            requestedContexts: PresentationContexts.verification)
        .associateOver(transport, aeTitle: 'PEER');
    await expectLater(
        a.sendCEcho(),
        throwsA(isA<AssociationAborted>()
            .having((e) => e.source, 'source', 2)
            .having((e) => e.reason, 'reason', 2)));
    await serving;
  });
  test('cancel while association response is pending closes ownership',
      () async {
    final (transport, peer) = ScriptedPeer.connect();
    final cancellation = AssociationCancellation();
    final pending = const ApplicationEntity(
            aeTitle: 'CLIENT',
            requestedContexts: PresentationContexts.verification)
        .associateOver(transport, aeTitle: 'PEER', cancellation: cancellation);
    final check = expectLater(
        pending,
        throwsA(isA<AssociationAborted>()
            .having((e) => e.locallyCancelled, 'local cancellation', true)));
    await peer.next();
    cancellation.cancel();
    await check.timeout(const Duration(seconds: 2));
  });
  test('rejection retains numeric fields without peer text', () async {
    final recorder = Recorder();
    final (transport, peer) = ScriptedPeer.connect();
    final serving = () async {
      await peer.next();
      await peer.send(const AssociateRj(result: 1, source: 1, reason: 7));
    }();
    await expectLater(
        ApplicationEntity(
                aeTitle: 'CLIENT',
                requestedContexts: PresentationContexts.verification,
                observer: recorder)
            .associateOver(transport, aeTitle: 'PEER'),
        throwsA(isA<AssociationRejected>()));
    await serving;
    final rejection = recorder.events
        .singleWhere((e) => e.kind == ObservationKind.associateReject);
    expect((rejection.result, rejection.source, rejection.reason), (1, 1, 7));
    expect(recorder.events.last.kind, ObservationKind.transportClosed);
  });
  test('rejected contexts and absent peer parameters remain explicit',
      () async {
    final recorder = Recorder();
    final (transport, peer) = ScriptedPeer.connect();
    final serving = () async {
      final rq = await peer.next() as AssociateRq;
      await peer.send(AssociateAc(
          calledAeTitle: rq.calledAeTitle,
          callingAeTitle: rq.callingAeTitle,
          results: [
            for (final c in rq.contexts)
              ContextResult(c.id, 3, c.transferSyntaxes.first)
          ],
          userInformation: const UserInformation(
              maxLength: 1024,
              implementationClassUid: '1.2.3',
              implementationVersionName: 'PRIVATE_CANARY')));
      await peer.acceptRelease();
    }();
    final a = await ApplicationEntity(
            aeTitle: 'CLIENT',
            requestedContexts: PresentationContexts.verification,
            observer: recorder)
        .associateOver(transport, aeTitle: 'PEER');
    expect(a.acceptedContexts, isEmpty);
    await a.release();
    await a.closed;
    await serving;
    final accepted = recorder.events
        .singleWhere((e) => e.kind == ObservationKind.associateAccept);
    expect(accepted.contexts.single.result, 3);
    expect(accepted.contexts.single.selectedTransferSyntax, isNull);
    expect(accepted.maxInvoked, isNull);
    expect(accepted.peerImplementationClassUid, '1.2.3');
    expect(recorder.events.last.kind, ObservationKind.transportClosed);
  });
  test('invalid UID fields cannot smuggle arbitrary peer text', () {
    final context = ContextObservation(
        id: 1,
        abstractSyntax: 'PRIVATE_CANARY',
        proposedTransferSyntaxes: ['1.2.3', 'PRIVATE_CANARY'],
        selectedTransferSyntax: 'PRIVATE_CANARY');
    expect(context.abstractSyntax, '');
    expect(context.proposedTransferSyntaxes, ['1.2.3']);
    expect(context.selectedTransferSyntax, isNull);
  });
  test('cancelling pending socket tasks drains late completions', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final subscription = server.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {}, onError: (_) {});
    });
    try {
      for (var i = 0; i < 20; i++) {
        final token = AssociationCancellation();
        final pending = SocketTransport.connect('localhost', server.port,
            cancellation: token);
        final check = expectLater(pending, throwsA(isA<AssociationAborted>()));
        token.cancel();
        await check;
      }
      // Let late lookup/socket futures settle; unhandled errors fail this test.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } finally {
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
    }
  });
  test('pre-cancelled connect dispatches no socket', () async {
    final cancellation = AssociationCancellation()..cancel();
    await expectLater(
        SocketTransport.connect('127.0.0.1', 1, cancellation: cancellation),
        throwsA(isA<AssociationAborted>()));
  });
}
