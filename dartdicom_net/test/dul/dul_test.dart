// The DUL in both roles (PS3.8 §9, blueprint F42): a requestor and an
// acceptor over an in-memory pair, or one of them against raw PDUs.
import 'dart:async';
import 'dart:typed_data';

import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dul/dul.dart';
import 'package:dartdicom_net/src/dul/framer.dart';
import 'package:dartdicom_net/src/fsm/table.dart';
import 'package:dartdicom_net/src/pdu/items.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:test/test.dart';

const _rq = AssociateRq(
  calledAeTitle: 'SCP',
  callingAeTitle: 'SCU',
  contexts: [
    ProposedContext(1, '1.2.840.10008.1.1', ['1.2.840.10008.1.2']),
  ],
  userInformation:
      UserInformation(maxLength: 16384, implementationClassUid: '1.2.3'),
);

const _ac = AssociateAc(
  calledAeTitle: 'SCP',
  callingAeTitle: 'SCU',
  results: [ContextResult(1, 0, '1.2.840.10008.1.2')],
  userInformation:
      UserInformation(maxLength: 16384, implementationClassUid: '1.2.4'),
);

final _data = PDataTf([
  Pdv(1, Uint8List.fromList([1, 2]), isCommand: true, isLast: true),
]);

/// An established requestor and acceptor, connected in memory.
Future<(Dul, Dul)> _established() async {
  final (a, b) = InMemoryTransport.pair();
  final requestor = Dul.requestor(a);
  final acceptor = Dul.acceptor(b);
  final answer = requestor.requestAssociation(_rq);
  expect((await acceptor.receiveRequest()).callingAeTitle, 'SCU');
  await acceptor.accept(_ac);
  await answer;
  return (requestor, acceptor);
}

/// The far end of a transport, speaking raw PDUs.
final class _Raw {
  _Raw(this.transport)
      : _pdus = StreamIterator(transport.incoming.transform(const PduFramer()));

  final InMemoryTransport transport;
  final StreamIterator<Uint8List> _pdus;

  Future<Pdu?> next() async =>
      await _pdus.moveNext() ? Pdu.decode(_pdus.current) : null;

  Future<void> send(Pdu pdu) => transport.send(pdu.encode());
  Future<void> sendBytes(List<int> bytes) =>
      transport.send(Uint8List.fromList(bytes));
}

void main() {
  group('the requestor', () {
    test('associates, transfers and releases', () async {
      final (requestor, acceptor) = await _established();
      expect(requestor.state, UlState.sta6);
      expect(acceptor.state, UlState.sta6);
      await requestor.send(_data);
      expect(await acceptor.receive(), isA<PDataTf>());
      await acceptor.send(_data);
      expect(await requestor.receive(), isA<PDataTf>());
      await Future.wait([requestor.release(), acceptor.receive()]);
      expect(await acceptor.receive(), isNull); // released
      await acceptor.ended;
      expect(requestor.state, UlState.sta1);
      expect(requestor.cause, isNull);
    });

    test('a peer release while idle is answered; the next call says so',
        () async {
      final (a, b) = InMemoryTransport.pair();
      final requestor = Dul.requestor(a);
      final peer = _Raw(b);
      final answer = requestor.requestAssociation(_rq);
      expect(await peer.next(), isA<AssociateRq>());
      await peer.send(_ac);
      await answer;
      await peer.send(const ReleaseRq());
      expect(await peer.next(), isA<ReleaseRp>()); // AR-2, then AR-4
      await peer.transport.close();
      await requestor.ended;
      expect(
          () => requestor.send(_data),
          throwsA(isA<AssociationAborted>()
              .having((e) => e.message, 'message', contains('peer released'))));
      expect(await requestor.receive(), isNull);
      await requestor.release(); // already released: returns
    });

    test('a peer abort while idle is the cause of every later call', () async {
      final (requestor, acceptor) = await _established();
      await acceptor.abort();
      await requestor.ended;
      for (final call in [
        () => requestor.send(_data),
        requestor.receive,
        requestor.release,
      ]) {
        await expectLater(call, throwsA(isA<AssociationAborted>()));
      }
      await requestor.abort(); // a no-op once ended
    });

    test('a local abort is the cause too, never a StateError', () async {
      final (requestor, acceptor) = await _established();
      await requestor.abort();
      expect(requestor.cause, isA<AssociationAborted>());
      expect(() => requestor.send(_data), throwsA(isA<AssociationAborted>()));
      await expectLater(acceptor.receive(), throwsA(isA<AssociationAborted>()));
    });

    test('a closed connection while idle ends the association', () async {
      final (a, b) = InMemoryTransport.pair();
      final requestor = Dul.requestor(a);
      final peer = _Raw(b);
      final answer = requestor.requestAssociation(_rq);
      await peer.next();
      await peer.send(_ac);
      await answer;
      await peer.transport.close();
      await requestor.ended;
      expect(
          requestor.cause,
          isA<AssociationAborted>().having((e) => e.message, 'message',
              contains('closed before the association was released')));
    });

    test('a rejection is thrown and recorded', () async {
      final (a, b) = InMemoryTransport.pair();
      final requestor = Dul.requestor(a);
      final peer = _Raw(b);
      final answer = requestor.requestAssociation(_rq);
      await peer.next();
      await peer.send(const AssociateRj(result: 1, source: 1, reason: 3));
      await expectLater(answer, throwsA(isA<AssociationRejected>()));
      expect(requestor.state, UlState.sta1);
    });

    test('an invalid PDU aborts with reason 1 (unrecognized)', () async {
      final (a, b) = InMemoryTransport.pair();
      final requestor = Dul.requestor(a);
      final peer = _Raw(b);
      final answer = requestor.requestAssociation(_rq);
      await peer.next();
      await peer.send(_ac);
      await answer;
      await peer.sendBytes([0x09, 0, 0, 0, 0, 2, 0, 0]); // no PDU type 0x09
      expect(
          await peer.next(), isA<Abort>().having((a) => a.reason, 'reason', 1));
      await requestor.ended;
      expect(requestor.cause, isA<DimseProtocolException>());
    });

    test('a failed send is the connection failing', () async {
      final (a, b) = InMemoryTransport.pair();
      final failing = _FailingTransport(a);
      final requestor = Dul.requestor(failing);
      final peer = _Raw(b);
      final answer = requestor.requestAssociation(_rq);
      await peer.next();
      await peer.send(_ac);
      await answer;
      failing.fail = true;
      await expectLater(
          requestor.send(_data),
          throwsA(isA<AssociationAborted>().having(
              (e) => e.message, 'message', contains('connection failed'))));
      expect(requestor.cause, isA<AssociationAborted>());
    });
  });

  group('the read-ahead (F42)', () {
    test('reads the next PDU only once the last is taken', () async {
      final lines = <String>[];
      final (a, b) = InMemoryTransport.pair();
      final requestor = Dul.requestor(a,
          trace: Trace(TraceSink.lines(lines.add), level: TraceLevel.pdu));
      final peer = _Raw(b);
      final answer = requestor.requestAssociation(_rq);
      await peer.next();
      await peer.send(_ac);
      await answer;
      await peer.send(_data);
      await peer.send(_data);
      int read() => lines.where((l) => l.startsWith('← PDU P-DATA-TF')).length;
      await pumpEventQueue();
      expect(read(), 1);
      await requestor.receive();
      await pumpEventQueue();
      expect(read(), 2);
    });

    test('an abort drops the PDU not yet taken: receive throws the cause',
        () async {
      final (requestor, acceptor) = await _established();
      await acceptor.send(_data);
      await pumpEventQueue();
      await requestor.abort();
      await expectLater(
          requestor.receive(), throwsA(isA<AssociationAborted>()));
    });
  });

  group('the acceptor', () {
    test('a PDU before the A-ASSOCIATE-RQ is aborted (AA-1)', () async {
      final (a, b) = InMemoryTransport.pair();
      final acceptor = Dul.acceptor(b);
      final peer = _Raw(a);
      final request = acceptor.receiveRequest();
      await peer.send(_data);
      await expectLater(request, throwsA(isA<DimseProtocolException>()));
      expect(await peer.next(), isA<Abort>());
    });

    test('rejects (AE-8), then the requestor closes', () async {
      final (a, b) = InMemoryTransport.pair();
      final acceptor = Dul.acceptor(b);
      final peer = _Raw(a);
      await peer.send(_rq);
      await acceptor.receiveRequest();
      await acceptor.reject(const AssociateRj(result: 1, source: 1, reason: 7));
      expect(await peer.next(),
          isA<AssociateRj>().having((r) => r.reason, 'reason', 7));
      expect(acceptor.state, UlState.sta13);
      await peer.transport.close();
      await acceptor.ended;
      await Future<void>.delayed(Duration.zero);
      expect(acceptor.state, UlState.sta1);
    });

    test('a peer release ends the serve loop with null', () async {
      final (requestor, acceptor) = await _established();
      final releasing = requestor.release();
      expect(await acceptor.receive(), isNull);
      await releasing;
      expect(requestor.cause, isNull);
      expect(acceptor.cause, isNull);
    });

    test('abort before the request just closes the connection', () async {
      final (a, b) = InMemoryTransport.pair();
      final acceptor = Dul.acceptor(b);
      final peer = _Raw(a);
      await acceptor.abort();
      expect(await peer.next(), isNull); // closed, no A-ABORT
    });
  });

  test('a release collision completes on both sides (AR-8 … AR-10)', () async {
    final (requestor, acceptor) = await _established();
    await Future.wait([requestor.release(), acceptor.release()])
        .timeout(const Duration(seconds: 5));
    expect(requestor.cause, isNull);
    expect(acceptor.cause, isNull);
    await acceptor.ended;
  });
}

/// A transport whose sends fail once [fail] is set, like a dropped socket.
final class _FailingTransport implements Transport {
  _FailingTransport(this._inner);

  final InMemoryTransport _inner;
  var fail = false;

  @override
  Stream<Uint8List> get incoming => _inner.incoming;

  @override
  Future<void> send(Uint8List bytes) async {
    if (fail) throw StateError('broken pipe');
    await _inner.send(bytes);
  }

  @override
  Future<void> close() => _inner.close();
}
