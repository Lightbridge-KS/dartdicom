import 'dart:async';
import 'dart:typed_data';

import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dul/dul.dart';
import 'package:dartdicom_net/src/fsm/table.dart';
import 'package:dartdicom_net/src/pdu/items.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

const _rq = AssociateRq(
    calledAeTitle: 'SCP',
    callingAeTitle: 'SCU',
    contexts: [
      ProposedContext(1, '1.2.3', ['1.2.4'])
    ],
    userInformation:
        UserInformation(maxLength: 16384, implementationClassUid: '1.2.5'));
const _ac = AssociateAc(
    calledAeTitle: 'SCP',
    callingAeTitle: 'SCU',
    results: [ContextResult(1, 0, '1.2.4')],
    userInformation:
        UserInformation(maxLength: 16384, implementationClassUid: '1.2.5'));

/// Accepts a send synchronously but leaves its completion under test control.
final class _StalledAbortTransport implements AbortableTransport {
  final abortSent = Completer<void>();
  final incomingBytes = StreamController<Uint8List>(onCancel: () async {});
  var closeCalls = 0;
  var destroyCalls = 0;

  @override
  Stream<Uint8List> get incoming => incomingBytes.stream;

  @override
  Future<void> send(Uint8List bytes) =>
      bytes.first == 7 ? abortSent.future : Future.value();

  @override
  Future<void> close() async {
    closeCalls++;
    unawaited(incomingBytes.close());
  }

  @override
  void destroy() {
    destroyCalls++;
  }
}

void main() {
  for (final trigger in [
    'local abort',
    'before request',
    'malformed',
    'unexpected'
  ]) {
    for (final lateError in [false, true]) {
      test('$trigger bounds a stalled abort send; late error=$lateError', () {
        fakeAsync((clock) {
          final transport = _StalledAbortTransport();
          final dul = trigger == 'before request'
              ? Dul.acceptor(transport)
              : Dul.requestor(transport);
          var closed = false;
          unawaited(dul.closed.then((_) => closed = true));
          if (trigger != 'before request') {
            unawaited(dul.requestAssociation(_rq));
            clock.flushMicrotasks();
            transport.incomingBytes.add(_ac.encode());
            clock.flushMicrotasks();
            expect(dul.state, UlState.sta6);
          }
          if (trigger == 'local abort') {
            unawaited(dul.abort());
          } else {
            transport.incomingBytes.add(trigger == 'malformed'
                ? Uint8List.fromList([9, 0, 0, 0, 0, 2, 0, 0])
                : const ReleaseRp().encode());
          }
          clock.flushMicrotasks();
          final cause = dul.cause;
          expect(
              cause,
              trigger == 'local abort'
                  ? isA<AssociationAborted>()
                  : isA<DimseProtocolException>());
          clock.elapse(const Duration(milliseconds: 999));
          expect(transport.closeCalls, 0);
          expect(closed, isFalse);
          clock.elapse(const Duration(milliseconds: 1));
          clock.flushMicrotasks();
          expect(transport.destroyCalls, greaterThan(0));
          expect(transport.closeCalls, 1);
          expect(closed, isTrue);
          expect(dul.state, UlState.sta1);
          expect(dul.cause, same(cause));
          // A late send completion must not escape or replace the outcome.
          if (lateError) {
            transport.abortSent.completeError(StateError('PRIVATE_CANARY'));
          } else {
            transport.abortSent.complete();
          }
          clock.flushMicrotasks();
          expect(dul.cause, same(cause));
          expect(transport.closeCalls, 1);
        });
      });
    }
  }
}
