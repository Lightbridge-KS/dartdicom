import 'dart:async';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/association/application_entity.dart';
import 'package:dartdicom_net/src/dimse/channel.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:dartdicom_net/src/dul/dul.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:dartdicom_net/src/trace/observations.dart'
    show ObservationRecorder;
import 'package:test/test.dart';

import '../support/peer.dart';

const _ae = ApplicationEntity(
    aeTitle: 'CLIENT', requestedContexts: PresentationContexts.verification);

final class _Recorder implements AssociationObserver {
  final events = <AssociationObservation>[];

  @override
  void record(AssociationObservation observation) => events.add(observation);

  Iterable<AssociationObservation> get outgoingDimse => events.where((e) =>
      e.kind == ObservationKind.dimse &&
      e.direction == ObservationDirection.outgoing);
}

/// Cleanup gates represent asynchronous work owned by an injected transport.
final class _CleanupTransport implements Transport {
  _CleanupTransport({this.closeGate, this.cancelGate});

  final Completer<void>? closeGate, cancelGate;
  final listening = Completer<void>();
  final cancelling = Completer<void>();
  var cancelFinished = false;
  var closeCalls = 0;
  late final _incoming = StreamController<Uint8List>(
      onListen: listening.complete,
      onCancel: () async {
        cancelling.complete();
        await cancelGate?.future;
        cancelFinished = true;
      });

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List bytes) async {}

  @override
  Future<void> close() async {
    closeCalls++;
    await closeGate?.future;
  }
}

final class _FailingCloseTransport implements Transport {
  _FailingCloseTransport(this.inner);
  final Transport inner;

  @override
  Stream<Uint8List> get incoming => inner.incoming;
  @override
  Future<void> send(Uint8List bytes) => inner.send(bytes);
  @override
  Future<void> close() async => throw StateError('PRIVATE_CANARY');
}

final class _ForcedCloseTransport extends _FailingCloseTransport
    implements AbortableTransport {
  _ForcedCloseTransport(super.inner, {required this.destroyFails});
  final bool destroyFails;
  var destroyCalls = 0;

  @override
  void destroy() {
    destroyCalls++;
    if (destroyFails) throw StateError('PRIVATE_CANARY');
    unawaited(inner.close());
  }
}

final class _RejectingSendTransport implements Transport {
  _RejectingSendTransport(this.inner);
  final Transport inner;

  @override
  Stream<Uint8List> get incoming => inner.incoming;
  @override
  Future<void> send(Uint8List bytes) {
    if (bytes.first == 0x04) throw StateError('PRIVATE_CANARY');
    return inner.send(bytes);
  }

  @override
  Future<void> close() => inner.close();
}

/// Holds the first submitted data PDU while another DIMSE send queues behind it.
final class _GatedSendTransport implements Transport {
  _GatedSendTransport(this.inner);
  final Transport inner;
  final submitted = Completer<void>();
  final unblock = Completer<void>();

  @override
  Stream<Uint8List> get incoming => inner.incoming;

  @override
  Future<void> send(Uint8List bytes) async {
    await inner.send(bytes);
    if (bytes.first == 0x04 && !submitted.isCompleted) {
      submitted.complete();
      await unblock.future;
    }
  }

  @override
  Future<void> close() => inner.close();
}

// Remove sub-item 0x51 from a real encoded AC rather than substituting a default
// in a test double. The fixed association header ends at byte 74 (PS3.8 §9.3.3).
Uint8List _withoutMaxLength(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  for (var at = 74; at < bytes.length;) {
    final length = data.getUint16(at + 2);
    if (bytes[at] == 0x50) {
      final subItem = at + 4;
      expect(bytes[subItem], 0x51);
      final out = Uint8List(bytes.length - 8)
        ..setRange(0, subItem, bytes)
        ..setRange(subItem, bytes.length - 8, bytes, subItem + 8);
      ByteData.sublistView(out)
        ..setUint16(at + 2, length - 8)
        ..setUint32(2, bytes.length - 14);
      return out;
    }
    at += 4 + length;
  }
  throw StateError('the AC has no User Information item');
}

void main() {
  group('cleanup completion', () {
    for (final phase in ['close', 'cancel']) {
      test('a stalled $phase fails closed without claiming cleanup', () async {
        final gate = Completer<void>();
        final transport = _CleanupTransport(
            closeGate: phase == 'close' ? gate : null,
            cancelGate: phase == 'cancel' ? gate : null);
        final recorder = _Recorder();
        final dul = Dul.requestor(transport,
            observations: ObservationRecorder(recorder, 'cleanup-$phase'));
        await transport.listening.future;
        final check = expectLater(
            dul.closed,
            throwsA(isA<AssociationAborted>().having(
                (e) => e.message, 'cleanup error', contains('cleanup'))));
        dul.forceClose();
        await check.timeout(const Duration(seconds: 3));
        expect(gate.isCompleted, isFalse);
        expect(transport.cancelFinished, phase == 'close');
        expect(
            recorder.events
                .where((e) => e.kind == ObservationKind.transportClosed),
            isEmpty);
        // Repeated teardown shares the same result; a late failure is drained.
        dul.forceClose();
        await expectLater(dul.closed, throwsA(isA<AssociationAborted>()));
        expect(transport.closeCalls, 1);
        gate.completeError(StateError('PRIVATE_CANARY'));
        await Future<void>.delayed(Duration.zero);
        expect(
            recorder.events
                .where((e) => e.kind == ObservationKind.transportClosed),
            isEmpty);
      });
    }

    test('confirmed cleanup completes once, including repeated forceClose',
        () async {
      final transport = _CleanupTransport();
      final recorder = _Recorder();
      final dul = Dul.requestor(transport,
          observations: ObservationRecorder(recorder, 'cleanup-success'));
      await transport.listening.future;
      dul.forceClose();
      dul.forceClose();
      await dul.closed;
      expect(transport.cancelFinished, isTrue);
      expect(transport.closeCalls, 1);
      expect(
          recorder.events
              .where((e) => e.kind == ObservationKind.transportClosed),
          hasLength(1));
    });

    for (final destroyFails in [false, true]) {
      test('forced teardown confirms cleanup only on success: $destroyFails',
          () async {
        final inner = _CleanupTransport();
        final transport =
            _ForcedCloseTransport(inner, destroyFails: destroyFails);
        final dul = Dul.requestor(transport);
        await inner.listening.future;
        final check = destroyFails
            ? expectLater(dul.closed, throwsA(isA<AssociationAborted>()))
            : expectLater(dul.closed, completes);
        dul.forceClose();
        await check;
        expect(inner.cancelFinished, isTrue);
        expect(transport.destroyCalls, greaterThan(0));
      });
    }

    test('cleanup failure does not replace Echo or release success', () async {
      final (transport, peer) = ScriptedPeer.connect();
      final serving = () async {
        await peer.accept();
        final request = await peer.nextMessage();
        await peer.sendMessage(DimseMessage(request.contextId,
            ScriptedPeer.response(CommandField.cEchoRsp, request, 0)));
        await peer.acceptRelease();
      }();
      final a = await _ae.associateOver(_FailingCloseTransport(transport),
          aeTitle: 'PEER');
      final closed = expectLater(
          a.closed,
          throwsA(isA<AssociationAborted>().having((e) => e.message,
              'private error omitted', isNot(contains('CANARY')))));
      expect(await a.sendCEcho(), isA<DimseSuccess>());
      await a.release();
      await closed;
      await serving;
      await transport.close();
    });

    test('cleanup failure preserves the original establishment rejection',
        () async {
      final (transport, peer) = ScriptedPeer.connect();
      final serving = () async {
        await peer.next();
        await peer.send(const AssociateRj(result: 1, source: 1, reason: 7));
      }();
      await expectLater(
          _ae.associateOver(_FailingCloseTransport(transport), aeTitle: 'PEER'),
          throwsA(isA<AssociationRejected>()));
      await serving;
      await transport.close();
    });
  });

  group('outgoing submissions', () {
    test('failed association encoding emits no outgoing request fact',
        () async {
      final recorder = _Recorder();
      final (transport, peer) = InMemoryTransport.pair();
      final drain = peer.incoming.listen((_) {});
      await expectLater(
          ApplicationEntity(
                  aeTitle: 'CLIENT',
                  requestedContexts: const [
                    PresentationContext(Uid('1.2.\u0100'))
                  ],
                  observer: recorder)
              .associateOver(transport, aeTitle: 'PEER'),
          throwsArgumentError);
      expect(
          recorder.events.where((e) =>
              e.kind == ObservationKind.associateRequest &&
              e.direction == ObservationDirection.outgoing),
          isEmpty);
      await drain.cancel();
      await peer.close();
    });

    test('synchronous transport rejection emits no outgoing DIMSE or data fact',
        () async {
      final (transport, peer) = ScriptedPeer.connect();
      final recorder = _Recorder();
      final serving = peer.accept();
      final a = await ApplicationEntity(
              aeTitle: 'CLIENT',
              requestedContexts: PresentationContexts.verification,
              observer: recorder)
          .associateOver(_RejectingSendTransport(transport), aeTitle: 'PEER');
      await serving;
      await expectLater(a.sendCEcho(), throwsA(isA<AssociationAborted>()));
      await a.closed;
      expect(recorder.outgoingDimse, isEmpty);
      expect(
          recorder.events.where((e) =>
              e.kind == ObservationKind.data &&
              e.direction == ObservationDirection.outgoing),
          isEmpty);
    });

    test('Echo after closed emits no outgoing DIMSE fact', () async {
      final (transport, peer) = ScriptedPeer.connect();
      final recorder = _Recorder();
      final serving = peer.accept();
      final a = await ApplicationEntity(
              aeTitle: 'CLIENT',
              requestedContexts: PresentationContexts.verification,
              observer: recorder)
          .associateOver(transport, aeTitle: 'PEER');
      await serving;
      a.forceClose();
      await a.closed;
      await expectLater(a.sendCEcho(), throwsA(isA<AssociationAborted>()));
      expect(recorder.outgoingDimse, isEmpty);
    });

    test('failed fragmentation emits no outgoing DIMSE fact', () async {
      final (transport, peer) = ScriptedPeer.connect();
      final recorder = _Recorder();
      final serving = peer.accept(maxLength: 6);
      final a = await ApplicationEntity(
              aeTitle: 'CLIENT',
              requestedContexts: PresentationContexts.verification,
              observer: recorder)
          .associateOver(transport, aeTitle: 'PEER');
      await serving;
      await expectLater(a.sendCEcho(), throwsA(isA<DimseProtocolException>()));
      expect(recorder.outgoingDimse, isEmpty);
      await a.abort();
      await a.closed;
    });

    test('a queued send cancelled before submission produces no fact',
        () async {
      final (inner, peer) = ScriptedPeer.connect();
      final transport = _GatedSendTransport(inner);
      final recorder = _Recorder();
      final dul = Dul.requestor(transport,
          observations: ObservationRecorder(recorder, 'queued'));
      final serving = peer.accept();
      await dul.requestAssociation(associateRqFor(_ae, 'PEER'));
      await serving;
      final channel = DimseChannel(dul, 16384);
      DimseMessage echo(int id) => DimseMessage(
          1,
          requestCommand(CommandField.cEchoRq, id, SopClasses.verification,
              hasDataset: false));
      final first = channel.send(echo(1));
      await transport.submitted.future;
      // A submission is observable even while the transport future is pending.
      expect(recorder.outgoingDimse.map((e) => e.messageId), [1]);
      final queued = channel.send(echo(2));
      final check = expectLater(queued, throwsA(isA<AssociationAborted>()));
      await dul.abort();
      transport.unblock.complete();
      await first;
      await check;
      await dul.closed;
      expect(recorder.outgoingDimse.map((e) => e.messageId), [1]);
    });
  });

  group('incoming closure', () {
    for (final bytes in [
      [0x99, 0, 0, 0, 0, 0], // Unknown PDU type.
      [0x04, 0, 0x7f, 0xff, 0xff, 0xff], // Invalid framing length.
    ]) {
      test('malformed input ${bytes.first} is not transport EOF', () async {
        final (transport, peer) = InMemoryTransport.pair();
        final recorder = _Recorder();
        final drain = peer.incoming.listen((_) {});
        final dul = Dul.acceptor(transport,
            observations: ObservationRecorder(recorder, 'malformed'));
        await peer.send(Uint8List.fromList(bytes));
        await dul.closed;
        expect(
            recorder.events.where((e) =>
                e.kind == ObservationKind.transportClosed &&
                e.direction == ObservationDirection.incoming),
            isEmpty);
        expect(
            recorder.events.where((e) =>
                e.kind == ObservationKind.transportClosed &&
                e.direction == ObservationDirection.local),
            hasLength(1));
        expect(recorder.events.any((e) => e.kind == ObservationKind.abort),
            isTrue);
        await drain.cancel();
        await peer.close();
      });
    }

    test('actual transport EOF retains the incoming closure fact', () async {
      final (transport, peer) = InMemoryTransport.pair();
      final recorder = _Recorder();
      final drain = peer.incoming.listen((_) {});
      final dul = Dul.acceptor(transport,
          observations: ObservationRecorder(recorder, 'eof'));
      await peer.close();
      await dul.closed;
      expect(
          recorder.events.where((e) =>
              e.kind == ObservationKind.transportClosed &&
              e.direction == ObservationDirection.incoming),
          hasLength(1));
      await drain.cancel();
    });
  });

  group('peer Max Length presence', () {
    for (final present in [false, true]) {
      test('absent versus explicitly unlimited: present=$present', () async {
        final (transport, peer) = ScriptedPeer.connect();
        final recorder = _Recorder();
        final serving = () async {
          final rq = await peer.next() as AssociateRq;
          final bytes = acWithoutRoles(rq).encode();
          if (present) {
            // Set the actual wire sub-item to zero (unlimited).
            for (var at = 74; at < bytes.length;) {
              final data = ByteData.sublistView(bytes);
              if (bytes[at] == 0x50) {
                data.setUint32(at + 8, 0);
                break;
              }
              at += 4 + data.getUint16(at + 2);
            }
          }
          await peer.transport.send(present ? bytes : _withoutMaxLength(bytes));
          final request = await peer.nextMessage();
          await peer.sendMessage(DimseMessage(request.contextId,
              ScriptedPeer.response(CommandField.cEchoRsp, request, 0)));
          await peer.acceptRelease();
        }();
        final a = await ApplicationEntity(
                aeTitle: 'CLIENT',
                requestedContexts: PresentationContexts.verification,
                observer: recorder)
            .associateOver(transport, aeTitle: 'PEER');
        final ac = recorder.events
            .singleWhere((e) => e.kind == ObservationKind.associateAccept);
        expect(ac.peerMaxPduLength, present ? 0 : isNull);
        // Preserve the existing networking fallback when Max Length is absent.
        expect(await a.sendCEcho(), isA<DimseSuccess>());
        await a.release();
        await a.closed;
        await serving;
      });
    }
  });
}
