import 'package:dartdicom/dartdicom.dart';

import '../acse/negotiation.dart';
import '../dimse/channel.dart';
import '../dimse/message.dart';
import '../dul/dul.dart';
import '../errors.dart';
import '../sink/instance_sink.dart';
import 'store.dart';

// The acceptor's side of a storage association (F3): the requests a
// StorageScp answers. Not exported: the general SCP and its public API come
// with N-15.

/// Serves the requests of one accepted association until the peer releases
/// it (a normal return) or it ends any other way (the cause is thrown):
/// C-ECHO gets success, C-STORE goes to [sink] through [storeInstance], a
/// C-CANCEL-RQ is ignored (nothing here runs long enough to cancel), and
/// any other request gets 0x0211, unrecognized operation.
Future<void> serveStorage(Dul dul, DimseChannel channel,
    List<AcceptedContext> contexts, InstanceSink sink,
    {required String peerAeTitle}) async {
  while (true) {
    dul.busy = false; // between requests, the network timer runs
    final DimseMessage rq;
    try {
      rq = await channel.receive(timed: false);
    } on AssociationAborted {
      if (dul.cause == null) return; // the peer released: the normal end
      rethrow;
    }
    dul.busy = true;
    final context = contexts.where((c) => c.id == rq.contextId).firstOrNull;
    final field = rq.commandField;
    final Dataset rsp;
    if (field == CommandField.cCancelRq) {
      continue;
    } else if (field == CommandField.cEchoRq) {
      rsp = responseCommand(CommandField.cEchoRsp, rq.messageId ?? 0,
          context == null ? 0x0122 : 0,
          sopClassUid: rq.affectedSopClassUid);
    } else if (field == CommandField.cStoreRq) {
      rsp = await storeInstance(rq, context, sink,
          mayStore: context?.scpRole ?? false, peerAeTitle: peerAeTitle);
    } else if (field & 0x8000 == 0) {
      rsp = responseCommand(field | 0x8000, rq.messageId ?? 0, 0x0211,
          sopClassUid: rq.affectedSopClassUid);
    } else {
      await channel.protocolAbort('a response arrived where a request '
          'was expected (command field $field)');
    }
    await channel.send(DimseMessage(rq.contextId, rsp));
  }
}
