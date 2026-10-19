/// DICOM networking (DIMSE) in pure Dart: associate with a PACS and run
/// C-ECHO, C-FIND and C-GET as an SCU. Native platforms only (`dart:io`).
///
/// ```dart
/// const ae = ApplicationEntity(
///     aeTitle: 'MYAPP', requestedContexts: PresentationContexts.verification);
/// final assoc = await ae.associate('pacs.local', 104, aeTitle: 'PACS');
/// final status = await assoc.sendCEcho();
/// await assoc.release();
/// ```
library;

export 'src/acse/negotiation.dart' show AcceptedContext;
export 'src/association/application_entity.dart' show ApplicationEntity;
export 'src/association/association.dart';
export 'src/association/presentation_contexts.dart';
export 'src/association/retrieve_progress.dart';
export 'src/dimse/status.dart';
export 'src/timeouts.dart';
export 'src/trace/trace.dart';
export 'src/errors.dart';
export 'src/scp/storage_scp.dart';
export 'src/sink/directory_sink.dart';
export 'src/sink/instance_sink.dart';
export 'src/transport/in_memory_transport.dart';
export 'src/transport/socket_transport.dart';
export 'src/transport/transport.dart';

export 'src/trace/observations.dart' hide ObservationRecorder;
export 'src/transport/cancellation.dart';
