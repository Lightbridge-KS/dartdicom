// The timers (PRD N-13): each under fake time, with the transports, the
// scripted peer and the association all built inside the fake zone. Every
// test checks its futures completed, so a hang can't pass.
import 'dart:async';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/association/application_entity.dart'
    show associateRqFor;
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:dartdicom_net/src/dul/dul.dart';
import 'package:dartdicom_net/src/fsm/table.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'support/peer.dart';

const _ae = ApplicationEntity(
  aeTitle: 'SCU',
  requestedContexts: [
    ...PresentationContexts.verification,
    ...PresentationContexts.studyRootQueryRetrieve,
  ],
);

/// How a future ended, observed without awaiting it (fake time can't).
final class _Outcome<T> {
  _Outcome(Future<T> future) {
    future.then((v) {
      value = v;
      done = true;
    }, onError: (Object e) {
      error = e;
      done = true;
    });
  }

  T? value;
  Object? error;
  var done = false;
}

Matcher _timeout(TimeoutKind kind) =>
    isA<DimseTimeout>().having((e) => e.kind, 'kind', kind);

/// An association with a scripted peer, established inside fake time.
(Association, ScriptedPeer) _established(FakeAsync async,
    {ApplicationEntity ae = _ae}) {
  final (ours, peer) = ScriptedPeer.connect();
  final assoc = _Outcome(ae.associateOver(ours, aeTitle: 'SCP'));
  _Outcome(peer.accept());
  async.flushMicrotasks();
  expect(assoc.done, isTrue);
  return (assoc.value!, peer);
}

void main() {
  test('the defaults are pynetdicom\'s', () {
    const t = Timeouts();
    expect(t.connect, const Duration(seconds: 30));
    expect(t.acse, const Duration(seconds: 30));
    expect(t.dimse, const Duration(seconds: 30));
    expect(t.network, const Duration(seconds: 60));
    expect(_ae.timeouts.dimse, const Duration(seconds: 30));
  });

  test('ACSE: no A-ASSOCIATE-AC within 30 s aborts', () {
    fakeAsync((async) {
      final (ours, peer) = ScriptedPeer.connect();
      final assoc = _Outcome(_ae.associateOver(ours, aeTitle: 'SCP'));
      final rq = _Outcome(peer.next());
      async.elapse(const Duration(seconds: 29));
      expect(rq.value, isA<AssociateRq>());
      expect(assoc.done, isFalse);
      final abort = _Outcome(peer.next());
      async.elapse(const Duration(seconds: 2));
      expect(assoc.error, _timeout(TimeoutKind.acse));
      expect(abort.value, isA<Abort>());
    });
  });

  test('ACSE: no A-RELEASE-RP within 30 s aborts', () {
    fakeAsync((async) {
      final (assoc, peer) = _established(async);
      final release = _Outcome(assoc.release());
      _Outcome(peer.next()); // the A-RELEASE-RQ, never answered
      async.elapse(const Duration(seconds: 31));
      expect(release.error, _timeout(TimeoutKind.acse));
    });
  });

  test('DIMSE: a response that never comes aborts, and stays the cause', () {
    fakeAsync((async) {
      final (assoc, peer) = _established(async);
      final echo = _Outcome(assoc.sendCEcho());
      _Outcome(peer.nextMessage());
      async.elapse(const Duration(seconds: 29));
      expect(echo.done, isFalse);
      final abort = _Outcome(peer.next());
      async.elapse(const Duration(seconds: 2));
      expect(echo.error, _timeout(TimeoutKind.dimse));
      expect(abort.value, isA<Abort>());
      final again = _Outcome(assoc.sendCEcho());
      async.flushMicrotasks();
      expect(again.error, _timeout(TimeoutKind.dimse));
    });
  });

  test('a custom DIMSE timeout is the one that applies', () {
    fakeAsync((async) {
      final (assoc, peer) = _established(async,
          ae: const ApplicationEntity(
              aeTitle: 'SCU',
              requestedContexts: PresentationContexts.verification,
              timeouts: Timeouts(dimse: Duration(seconds: 5))));
      final echo = _Outcome(assoc.sendCEcho());
      _Outcome(peer.nextMessage());
      async.elapse(const Duration(seconds: 6));
      expect(
          echo.error,
          isA<DimseTimeout>().having(
              (e) => e.message, 'message', contains('dimse timeout (5 s)')));
    });
  });

  test('network: an idle association is aborted after 60 s', () {
    fakeAsync((async) {
      final (assoc, peer) = _established(async);
      final abort = _Outcome(peer.next());
      async.elapse(const Duration(seconds: 59));
      expect(abort.done, isFalse);
      async.elapse(const Duration(seconds: 2));
      expect(abort.value, isA<Abort>());
      final echo = _Outcome(assoc.sendCEcho());
      async.flushMicrotasks();
      expect(echo.error, _timeout(TimeoutKind.network));
    });
  });

  test('network: a long operation is never cut by it', () {
    fakeAsync((async) {
      final (assoc, peer) = _established(async);
      final matches = <Dataset>[];
      final find = _Outcome(assoc
          .sendCFind(Dataset()..set(DicomTags.queryRetrieveLevel, 'STUDY'))
          .forEach(matches.add));
      final rq = _Outcome(peer.nextMessage());
      async.flushMicrotasks();
      // A pending match every 25 s for over two minutes: within the DIMSE
      // timeout each time, and past the network timeout in all.
      for (var i = 0; i < 6; i++) {
        async.elapse(const Duration(seconds: 25));
        _Outcome(peer.sendMessage(DimseMessage(
            rq.value!.contextId,
            ScriptedPeer.response(CommandField.cFindRsp, rq.value!, 0xFF00,
                hasDataset: true),
            (Dataset()..set(DicomTags.queryRetrieveLevel, 'STUDY')).toBytes(
                transferSyntax: TransferSyntaxes.explicitVrLittleEndian))));
        async.flushMicrotasks();
      }
      _Outcome(peer.sendMessage(DimseMessage(rq.value!.contextId,
          ScriptedPeer.response(CommandField.cFindRsp, rq.value!, 0x0000))));
      async.flushMicrotasks();
      expect(find.done, isTrue);
      expect(find.error, isNull);
      expect(matches, hasLength(6));
    });
  });

  group('ARTIM (the ACSE value)', () {
    test('an acceptor given no A-ASSOCIATE-RQ closes after 30 s', () {
      fakeAsync((async) {
        final (theirs, ours) = InMemoryTransport.pair();
        final dul = Dul.acceptor(ours);
        final request = _Outcome(dul.receiveRequest());
        ScriptedPeer(theirs); // connected, and silent
        async.elapse(const Duration(seconds: 29));
        expect(request.done, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(request.error, _timeout(TimeoutKind.acse));
        expect(dul.state, UlState.sta1); // the connection is closed
      });
    });

    test('after a rejection, a requestor that never closes is closed', () {
      fakeAsync((async) {
        final (theirs, ours) = InMemoryTransport.pair();
        final dul = Dul.acceptor(ours);
        final peer = ScriptedPeer(theirs);
        final rq = associateRqFor(_ae, 'SCP');
        _Outcome(peer.send(rq));
        _Outcome(dul.receiveRequest().then((_) =>
            dul.reject(const AssociateRj(result: 1, source: 1, reason: 7))));
        async.flushMicrotasks();
        expect(dul.state, UlState.sta13);
        async.elapse(const Duration(seconds: 31));
        expect(dul.state, UlState.sta1);
      });
    });
  });

  test('a connect timeout names the setting, and aborts nothing', () {
    final e = DimseTimeout(TimeoutKind.connect, const Duration(seconds: 30));
    expect(e.message, contains('Timeouts.connect'));
    expect(e.message, isNot(contains('aborted')));
  });
}
