// A scripted peer for association tests: the far end of an
// InMemoryTransport, driven step by step by the test.
import 'dart:async';
import 'dart:typed_data';

import 'package:dartdicom/dartdicom.dart';
import 'package:dartdicom_net/dartdicom_net.dart';
import 'package:dartdicom_net/src/dimse/fragments.dart';
import 'package:dartdicom_net/src/dimse/message.dart';
import 'package:dartdicom_net/src/dul/framer.dart';
import 'package:dartdicom_net/src/pdu/items.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';

final class ScriptedPeer {
  ScriptedPeer(this.transport)
      : _pdus = StreamIterator(transport.incoming.transform(const PduFramer()));

  /// A connected pair: the transport for the code under test, and the peer.
  static (InMemoryTransport, ScriptedPeer) connect() {
    final (ours, theirs) = InMemoryTransport.pair();
    return (ours, ScriptedPeer(theirs));
  }

  final InMemoryTransport transport;
  final StreamIterator<Uint8List> _pdus;
  final _assembler = Assembler();
  AssociateRq? request;

  Future<Pdu> next() async {
    if (!await _pdus.moveNext()) throw StateError('the requestor closed');
    return Pdu.decode(_pdus.current);
  }

  Future<void> send(Pdu pdu) => transport.send(pdu.encode());

  /// Reads the A-ASSOCIATE-RQ and accepts every context with its first
  /// transfer syntax, and every proposed role.
  Future<AssociateRq> accept({int maxLength = 16384}) async {
    final rq = request = await next() as AssociateRq;
    await send(AssociateAc(
      calledAeTitle: rq.calledAeTitle,
      callingAeTitle: rq.callingAeTitle,
      results: [
        for (final c in rq.contexts)
          ContextResult(c.id, 0, c.transferSyntaxes.first),
      ],
      userInformation: UserInformation(
          maxLength: maxLength,
          implementationClassUid: '1.2.3.4',
          implementationVersionName: 'PEER',
          roles: rq.userInformation.roles),
    ));
    return rq;
  }

  /// The context ID the requestor proposed for [sopClass].
  int contextFor(Uid sopClass) => request!.contexts
      .firstWhere((c) => c.abstractSyntax == sopClass.value)
      .id;

  /// The next whole DIMSE message from the requestor.
  Future<DimseMessage> nextMessage() async {
    while (true) {
      final pdu = await next();
      if (pdu is! PDataTf) throw StateError('expected P-DATA-TF, got $pdu');
      final done = _assembler.feed(pdu);
      if (done.isNotEmpty) return done.single;
    }
  }

  /// Sends [message], fragmented for [maxPduLength], [pdvsPerPdu] PDVs to a
  /// P-DATA-TF (to test several PDVs in one PDU).
  Future<void> sendMessage(DimseMessage message,
      {int maxPduLength = 16384, int pdvsPerPdu = 1}) async {
    final pdvs = [
      for (final pdu in fragment(message, maxPduLength)) ...pdu.pdvs
    ];
    for (var i = 0; i < pdvs.length; i += pdvsPerPdu) {
      await send(PDataTf(pdvs.sublist(
          i, i + pdvsPerPdu > pdvs.length ? pdvs.length : i + pdvsPerPdu)));
    }
  }

  /// A response command: [field], responding to [request], with [status].
  static Dataset response(int field, DimseMessage request, int status,
      {bool hasDataset = false}) {
    final ds = Dataset()
      ..set(DicomTags.commandField, field)
      ..set(DicomTags.messageIdBeingRespondedTo, request.messageId!)
      ..set(DicomTags.commandDataSetType, hasDataset ? 0x0001 : noDataset)
      ..set(DicomTags.status, status);
    final sopClass = request.affectedSopClassUid;
    if (sopClass != null) ds.set(DicomTags.affectedSopClassUid, sopClass);
    return ds;
  }

  /// Answers A-RELEASE-RQ and closes.
  Future<void> acceptRelease() async {
    final pdu = await next();
    if (pdu is! ReleaseRq) throw StateError('expected A-RELEASE-RQ, got $pdu');
    await send(const ReleaseRp());
    await transport.close();
  }
}

/// An A-ASSOCIATE-AC accepting every context of [rq] with its first
/// transfer syntax, but echoing no role selection items.
AssociateAc acWithoutRoles(AssociateRq rq) => AssociateAc(
      calledAeTitle: rq.calledAeTitle,
      callingAeTitle: rq.callingAeTitle,
      results: [
        for (final c in rq.contexts)
          ContextResult(c.id, 0, c.transferSyntaxes.first),
      ],
      userInformation: const UserInformation(
          maxLength: 16384, implementationClassUid: '1.2.3.4'),
    );
