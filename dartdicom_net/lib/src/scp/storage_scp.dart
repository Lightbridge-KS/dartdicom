import 'dart:async';
import 'dart:io';

import '../acse/acceptor.dart';
import '../association/serve.dart';
import '../dimse/channel.dart';
import '../dul/dul.dart';
import '../errors.dart';
import '../sink/instance_sink.dart';
import '../timeouts.dart';
import '../trace/record.dart';
import '../trace/trace.dart';
import '../transport/socket_transport.dart';

/// A peer a [StorageScp] accepts associations from: its calling AE title
/// and, optionally, the host it must connect from (blueprint F43). AE
/// titles are no authentication, since any host can claim one, so pinning
/// the host is worth it wherever the PACS's address is known.
final class ScpPeer {
  const ScpPeer(this.aeTitle, {this.host});

  /// The calling AE title, as the peer sends it.
  final String aeTitle;

  /// A host name or address the peer must connect from; `null` accepts the
  /// AE title from any host.
  final String? host;

  @override
  String toString() => 'ScpPeer($aeTitle${host == null ? '' : ', $host'})';
}

/// The embedded Storage SCP (PRD N-09): it listens on a port, accepts
/// associations from [ScpPeer]s only, and hands each instance stored over
/// them to a sink, as received. The destination of a C-MOVE.
///
/// ```dart
/// final scp = await StorageScp.start(
///     aeTitle: 'MYAPP', port: 11113,
///     sink: DirectorySink(Directory('incoming')),
///     acceptFrom: [ScpPeer('PACS', host: 'pacs.example')]);
/// // … sendCMove(query, destination: 'MYAPP') on another association …
/// await scp.close();
/// ```
///
/// Associations are served concurrently, up to [maxAssociations]; the sink
/// may therefore be called concurrently. A failure ends only its own
/// association: nothing escapes to the caller, and the listener goes on.
final class StorageScp {
  StorageScp._(
      this._server,
      this.aeTitle,
      this._sink,
      this.acceptFrom,
      this._hosts,
      this.timeouts,
      this.maxPduLength,
      this.maxAssociations,
      this.trace) {
    _server.listen(_connected, onError: (Object _) {});
  }

  /// Binds [port] (0 picks a free one; see [port]) on [address], every
  /// IPv4 interface by default, and starts accepting associations called
  /// [aeTitle] from [acceptFrom]. Each peer's host is resolved now.
  ///
  /// Associations are rejected as pynetdicom rejects them: (1,1,7) for a
  /// called AE title that isn't [aeTitle]; (1,1,3) for a calling AE title
  /// or host not in [acceptFrom]; (2,3,2) past [maxAssociations].
  static Future<StorageScp> start({
    required String aeTitle,
    required InstanceSink sink,
    required List<ScpPeer> acceptFrom,
    int port = 0,
    InternetAddress? address,
    Timeouts timeouts = const Timeouts(),
    int maxPduLength = 16384,
    int maxAssociations = 10,
    Trace? trace,
  }) async {
    if (aeTitle.trim().isEmpty || aeTitle.length > 16) {
      throw ArgumentError.value(
          aeTitle, 'aeTitle', 'must be 1–16 printable ASCII characters');
    }
    final hosts = <ScpPeer, Set<String>>{
      for (final peer in acceptFrom)
        if (peer.host case final host?)
          peer: {
            for (final a in await InternetAddress.lookup(host)) _normal(a),
          },
    };
    final server =
        await ServerSocket.bind(address ?? InternetAddress.anyIPv4, port);
    return StorageScp._(server, aeTitle, sink, List.unmodifiable(acceptFrom),
        hosts, timeouts, maxPduLength, maxAssociations, trace);
  }

  final ServerSocket _server;
  final InstanceSink _sink;
  final Map<ScpPeer, Set<String>> _hosts;

  /// The AE title peers must call.
  final String aeTitle;

  /// The peers whose associations are accepted.
  final List<ScpPeer> acceptFrom;

  final Timeouts timeouts;
  final int maxPduLength;
  final int maxAssociations;
  final Trace? trace;

  final _associations = <Dul>{};
  final _serving = <Future<void>>{};
  Future<void>? _closing;

  /// The port it listens on.
  int get port => _server.port;

  /// Stops listening, aborts the associations still open, and completes
  /// once every one has finished, an instance being stored included. Safe
  /// to call more than once.
  Future<void> close() => _closing ??= () async {
        await _server.close();
        await Future.wait(
            [for (final dul in _associations.toList()) dul.abort()]);
        await Future.wait(_serving.toList());
      }();

  void _connected(Socket socket) {
    if (_closing != null) {
      socket.destroy();
      return;
    }
    final dul =
        Dul.acceptor(SocketTransport(socket), timeouts: timeouts, trace: trace);
    _associations.add(dul);
    late final Future<void> serving;
    serving = _serve(dul, socket.remoteAddress).whenComplete(() {
      _associations.remove(dul);
      _serving.remove(serving);
    });
    _serving.add(serving);
  }

  /// One association, start to end. Nothing escapes: a failure ends this
  /// association only (its PDUs and cause are in the trace).
  Future<void> _serve(Dul dul, InternetAddress remote) async {
    try {
      final rq = await dul.receiveRequest();
      if (_refusal(rq.calledAeTitle, rq.callingAeTitle, remote)
          case final refusal?) {
        await dul.reject(refusal.rj);
        return;
      }
      final (ac, contexts) = acceptStorage(rq, maxPduLength: maxPduLength);
      await dul.accept(ac);
      await serveStorage(
          dul, DimseChannel(dul, rq.userInformation.maxLength), contexts, _sink,
          peerAeTitle: rq.callingAeTitle.trim());
    } on Object catch (e) {
      trace?.recordPdu(
          outgoing: false,
          summary: 'association ended: '
              '${e is DimseException ? e.message : e.runtimeType}');
      try {
        await dul.abort();
      } on Object {
        // Already closed.
      }
    }
  }

  Refusal? _refusal(String called, String calling, InternetAddress remote) {
    if (called.trim() != aeTitle.trim()) return Refusal.calledAeTitle;
    final from = _normal(remote);
    final allowed = acceptFrom.any((peer) =>
        peer.aeTitle == calling.trim() &&
        (peer.host == null || (_hosts[peer]?.contains(from) ?? false)));
    if (!allowed) return Refusal.callingAeTitle;
    if (_associations.length > maxAssociations) return Refusal.tooMany;
    return null;
  }

  /// An address as text, IPv4-mapped IPv6 (`::ffff:a.b.c.d`) as IPv4.
  static String _normal(InternetAddress a) {
    final text = a.address;
    return text.startsWith('::ffff:') && a.type == InternetAddressType.IPv6
        ? text.substring(7)
        : text;
  }

  @override
  String toString() => 'StorageScp($aeTitle, port $port)';
}
