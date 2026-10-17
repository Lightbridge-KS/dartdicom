// The interop matrix against DCMTK (M3 decision 2): dcmqrscp as the
// query/retrieve peer, storescp as the store peer, and storescu storing into
// our StorageScp. The peers come from scripts/interop_peers.sh.
@TestOn('vm')
@Tags(['live'])
library;

import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

import 'support.dart';

const _fixture = '../fixtures/data/synthetic/ct_signed_explicit_le.dcm';

void main() {
  final qr = needs('INTEROP_DCMQRSCP', 'DCMTK dcmqrscp');
  final store = needs('INTEROP_STORESCP', 'DCMTK storescp');
  Peer dcmqrscp() => peerAt('INTEROP_DCMQRSCP', 'DCMQRSCP');
  Peer storescp() => peerAt('INTEROP_STORESCP', 'STORESCP');

  test('C-ECHO → storescp', () => expectEcho(storescp()), skip: store);

  test('C-STORE → storescp, which writes the file', () async {
    final before = filesIn(env['INTEROP_STORESCP_DIR']!).length;
    await expectStore(storescp(), _fixture);
    expect(filesIn(env['INTEROP_STORESCP_DIR']!), hasLength(before + 1));
  }, skip: store);

  test('C-FIND → dcmqrscp', () => expectFind(dcmqrscp()), skip: qr);

  test('C-GET → dcmqrscp', () => expectGet(dcmqrscp()), skip: qr);

  test('C-MOVE → dcmqrscp, into our StorageScp',
      () => expectMove(dcmqrscp(), mover: 'DCMQRSCP'),
      skip: qr);

  test('storescu → our StorageScp, in Explicit and Implicit VR', () async {
    final stored = await storedBy('STORESCU', (port) async {
      for (final syntax in ['-xe', '-xi']) {
        final result = await Process.run(env['INTEROP_STORESCU']!, [
          syntax,
          '-aet', 'STORESCU', '-aec', ourAeTitle, //
          '127.0.0.1', '$port', _fixture,
        ]);
        if (result.exitCode != 0) return result;
      }
      return ProcessResult(0, 0, '', '');
    });
    expect([
      for (final i in stored) i.transferSyntax
    ], [
      TransferSyntaxes.explicitVrLittleEndian,
      TransferSyntaxes.implicitVrLittleEndian,
    ]);
    expect(stored.first.sourceAeTitle, 'STORESCU');
  }, skip: store);
}
