// The embedded StorageScp (PRD N-09, F3, F43) over real localhost sockets,
// with dartdicom's own SCU on the other end: who it accepts, what it
// negotiates, what it answers, and how it ends.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/association/application_entity.dart'
    show associateRqFor;
import 'package:dartdicom_net/src/dimse/channel.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:dartdicom_net/src/dul/dul.dart';
import 'package:test/test.dart';

const _ct = SopClasses.ctImageStorage;
const _jpegBaseline = Uid('1.2.840.10008.1.2.4.50');

final _file = DicomFile.fromBytes(
    File('../fixtures/data/synthetic/ct_signed_explicit_le.dcm')
        .readAsBytesSync());

ApplicationEntity _scu(
        {String aeTitle = 'SCU', List<PresentationContext>? contexts}) =>
    ApplicationEntity(
        aeTitle: aeTitle,
        requestedContexts: contexts ??
            [
              ...PresentationContexts.verification,
              ...PresentationContexts.storage([_ct]),
            ]);

Future<StorageScp> _start(InstanceSink sink,
        {List<ScpPeer> acceptFrom = const [ScpPeer('SCU')],
        int maxAssociations = 10}) =>
    StorageScp.start(
        aeTitle: 'DARTDICOM',
        sink: sink,
        acceptFrom: acceptFrom,
        address: InternetAddress.loopbackIPv4,
        maxAssociations: maxAssociations);

Future<Association> _associate(StorageScp scp,
        {ApplicationEntity? ae, String called = 'DARTDICOM'}) =>
    (ae ?? _scu()).associate('127.0.0.1', scp.port, aeTitle: called);

Matcher _rejected(int result, int source, int reason) =>
    isA<AssociationRejected>().having((e) => (e.result, e.source, e.reason),
        'reason', (result, source, reason));

void main() {
  test('stores what an allowed peer sends, echoes, and ends on release',
      () async {
    final sink = MemorySink();
    final scp = await _start(sink);
    final assoc = await _associate(scp);
    expect(await assoc.sendCEcho(), isA<DimseSuccess>());
    expect(await assoc.sendCStore(_file), isA<DimseSuccess>());
    await assoc.release();
    await scp.close();
    final instance = sink.instances.single;
    expect(instance.sourceAeTitle, 'SCU');
    expect(instance.sopInstanceUid.value,
        _file.dataset.require(DicomTags.sopInstanceUid));
    expect(instance.transferSyntax, TransferSyntaxes.explicitVrLittleEndian);
    expect(
        instance.bytes,
        _file.dataset
            .toBytes(transferSyntax: TransferSyntaxes.explicitVrLittleEndian));
  });

  group('rejections (F43, pynetdicom\'s reasons)', () {
    test('a called AE title that is not ours: (1,1,7)', () async {
      final scp = await _start(MemorySink());
      await expectLater(
          _associate(scp, called: 'SOMEONE'), throwsA(_rejected(1, 1, 7)));
      await scp.close();
    });

    test('a calling AE title not allowed: (1,1,3)', () async {
      final scp = await _start(MemorySink());
      await expectLater(_associate(scp, ae: _scu(aeTitle: 'STRANGER')),
          throwsA(_rejected(1, 1, 3)));
      await scp.close();
    });

    test('a peer pinned to a host is accepted only from it', () async {
      final elsewhere = await _start(MemorySink(),
          acceptFrom: const [ScpPeer('SCU', host: '192.0.2.1')]);
      await expectLater(_associate(elsewhere), throwsA(_rejected(1, 1, 3)));
      await elsewhere.close();
      final here = await _start(MemorySink(),
          acceptFrom: const [ScpPeer('SCU', host: '127.0.0.1')]);
      final assoc = await _associate(here);
      await assoc.release();
      await here.close();
    });

    test('past maxAssociations: (2,3,2), transient', () async {
      final scp = await _start(MemorySink(), maxAssociations: 1);
      final first = await _associate(scp);
      await expectLater(_associate(scp), throwsA(_rejected(2, 3, 2)));
      await first.release();
      await scp.close();
    });
  });

  group('negotiation (decision 4)', () {
    test('uncompressed is preferred, compressed accepted as a fallback',
        () async {
      final scp = await _start(MemorySink());
      final both = await _associate(scp,
          ae: _scu(contexts: [
            const PresentationContext(_ct, transferSyntaxes: [
              _jpegBaseline,
              TransferSyntaxes.explicitVrLittleEndian,
            ]),
          ]));
      expect(both.acceptedContexts.single.transferSyntax,
          TransferSyntaxes.explicitVrLittleEndian);
      await both.release();
      final compressed = await _associate(scp,
          ae: _scu(contexts: [
            const PresentationContext(_ct, transferSyntaxes: [_jpegBaseline]),
          ]));
      expect(compressed.acceptedContexts.single.transferSyntax, _jpegBaseline);
      await compressed.release();
      await scp.close();
    });

    test('a class it doesn\'t serve is rejected; the rest are accepted',
        () async {
      final scp = await _start(MemorySink());
      final assoc = await _associate(scp,
          ae: _scu(contexts: [
            ...PresentationContexts.studyRootQueryRetrieve,
            ...PresentationContexts.verification,
          ]));
      expect([for (final c in assoc.acceptedContexts) c.abstractSyntax],
          [SopClasses.verification]);
      await assoc.release();
      await scp.close();
    });
  });

  test('an unknown request gets 0x0211, and the association goes on', () async {
    final scp = await _start(MemorySink());
    final dul =
        Dul.requestor(await SocketTransport.connect('127.0.0.1', scp.port));
    final ac =
        await dul.requestAssociation(associateRqFor(_scu(), 'DARTDICOM'));
    final channel = DimseChannel(dul, ac.userInformation.maxLength);
    final verification = ac.results.first.id;
    await channel.send(DimseMessage(
        verification,
        requestCommand(CommandField.cFindRq, 1, SopClasses.verification,
            hasDataset: false)));
    final rsp = await channel.receive();
    expect(rsp.commandField, CommandField.cFindRsp);
    expect(rsp.status, 0x0211);
    await channel.send(DimseMessage(
        verification,
        requestCommand(CommandField.cEchoRq, 2, SopClasses.verification,
            hasDataset: false)));
    expect((await channel.receive()).status, 0x0000);
    await dul.release();
    await scp.close();
  });

  test('close() aborts open associations and waits for a store in flight',
      () async {
    final gate = Completer<void>();
    final sink = _GatedSink(gate.future);
    final scp = await _start(sink);
    final assoc = await _associate(scp);
    // The SCP aborts this association, so the store fails on our side.
    final store =
        expectLater(assoc.sendCStore(_file), throwsA(isA<DimseException>()));
    await sink.entered.future;
    var closed = false;
    final closing = scp.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(closed, isFalse); // the store is still being written
    gate.complete();
    await closing;
    await store;
    await scp.close(); // twice is fine
  });

  test('the same instance from two associations at once is stored whole',
      () async {
    final root = await Directory.systemTemp.createTemp('scp_test');
    addTearDown(() => root.delete(recursive: true));
    final sink = DirectorySink(root);
    final scp = await _start(sink);
    final a = await _associate(scp);
    final b = await _associate(scp);
    final statuses =
        await Future.wait([a.sendCStore(_file), b.sendCStore(_file)]);
    expect(statuses, everyElement(isA<DimseSuccess>()));
    await Future.wait([a.release(), b.release()]);
    await scp.close();
    final files = root
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path)
        .toList();
    expect(files, hasLength(1));
    expect(files.single, endsWith('.dcm'));
    expect(
        DicomFile.fromBytes(File(files.single).readAsBytesSync())
            .dataset
            .require(DicomTags.sopInstanceUid),
        _file.dataset.require(DicomTags.sopInstanceUid));
  });

  test('mutated association requests never break the listener', () async {
    final sink = MemorySink();
    final scp = await _start(sink);
    final valid = associateRqFor(_scu(), 'DARTDICOM').encode();
    final random = Random(7);
    for (var i = 0; i < 150; i++) {
      final bytes = Uint8List.fromList(valid);
      for (var flips = 1 + random.nextInt(6); flips > 0; flips--) {
        bytes[random.nextInt(bytes.length)] ^= 1 << random.nextInt(8);
      }
      final cut =
          random.nextInt(4) == 0 ? random.nextInt(bytes.length) : bytes.length;
      final socket = await Socket.connect('127.0.0.1', scp.port);
      socket.add(Uint8List.sublistView(bytes, 0, cut));
      await socket.flush();
      if (cut < bytes.length) await socket.close();
      // Whatever the answer (AC, RJ, A-ABORT, a closed connection), take it
      // and hang up; the listener must still be there afterwards.
      await socket.first
          .timeout(const Duration(seconds: 2), onTimeout: () => Uint8List(0))
          .catchError((Object _) => Uint8List(0));
      socket.destroy();
    }
    final assoc = await _associate(scp);
    expect(await assoc.sendCStore(_file), isA<DimseSuccess>());
    await assoc.release();
    await scp.close();
    expect(sink.instances, hasLength(1));
  });
}

/// A sink that signals when a store starts, and holds it until [_gate].
final class _GatedSink implements InstanceSink {
  _GatedSink(this._gate);

  final Future<void> _gate;
  final entered = Completer<void>();

  @override
  Future<void> accept(ReceivedInstance instance) async {
    entered.complete();
    await _gate;
  }
}
