import 'package:dartdicom/dartdicom.dart';

import '../acse/negotiation.dart';
import '../dimse/message.dart';
import '../sink/instance_sink.dart';

/// Takes the instance of one C-STORE-RQ into [sink] and returns the
/// C-STORE-RSP to send back: for a C-GET's sub-operations (the requestor)
/// and for a StorageScp's associations (the acceptor) alike.
///
/// - [context] is the presentation context the request came on, and
///   [mayStore] whether this side holds the SCP role on it; without both,
///   0x0122 (SOP class not supported).
/// - A request missing its SOP UIDs or dataset gets 0xC211, and so does a
///   [sink] that throws an [Exception]: the peer counts that instance as
///   failed and carries on.
/// - [peerAeTitle] becomes the instance's source AE title, (0002,0016).
Future<Dataset> storeInstance(
    DimseMessage rq, AcceptedContext? context, InstanceSink sink,
    {required bool mayStore, required String peerAeTitle}) async {
  if (context == null || !mayStore) return refusedStore(rq);
  final sopClass = rq.affectedSopClassUid;
  final sopInstance = rq.affectedSopInstanceUid;
  final int status;
  if (sopClass == null || sopInstance == null || rq.dataset == null) {
    status = 0xC211;
  } else {
    status = await _accept(
        sink,
        ReceivedInstance(
          sopClassUid: Uid(sopClass),
          sopInstanceUid: Uid(sopInstance),
          transferSyntax: context.transferSyntax,
          bytes: rq.dataset!,
          sourceAeTitle: peerAeTitle,
          moveOriginatorAeTitle:
              rq.command.get(DicomTags.moveOriginatorApplicationEntityTitle),
          moveOriginatorMessageId:
              rq.command.get(DicomTags.moveOriginatorMessageId),
        ));
  }
  return _response(rq, status);
}

/// The C-STORE-RSP refusing [rq]: 0x0122, SOP class not supported.
Dataset refusedStore(DimseMessage rq) => _response(rq, 0x0122);

Dataset _response(DimseMessage rq, int status) =>
    responseCommand(CommandField.cStoreRsp, rq.messageId ?? 0, status,
        sopClassUid: rq.affectedSopClassUid,
        sopInstanceUid: rq.affectedSopInstanceUid);

Future<int> _accept(InstanceSink sink, ReceivedInstance instance) async {
  try {
    await sink.accept(instance);
    return 0x0000;
  } on Exception {
    return 0xC211; // the sink failed; the peer counts it as failed
  }
}
