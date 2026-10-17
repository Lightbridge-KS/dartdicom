// The interop matrix against pynetdicom 3.0.4 (M3 decision 2): its qrscp as
// the query/retrieve peer, its storescp as the store peer, and its storescu
// storing into our StorageScp. The peers come from scripts/interop_peers.sh.
@TestOn('vm')
@Tags(['live'])
library;

import 'dart:io';

import 'package:dartdicom/dartdicom.dart';
import 'package:test/test.dart';

import 'support.dart';

const _fixture = '../fixtures/data/synthetic/ct_signed_explicit_le.dcm';

void main() {
  final qr = needs('INTEROP_QRSCP', 'pynetdicom qrscp');
  final store = needs('INTEROP_PYSTORESCP', 'pynetdicom storescp');
  Peer qrscp() => peerAt('INTEROP_QRSCP', 'QRSCP');
  Peer storescp() => peerAt('INTEROP_PYSTORESCP', 'PYSTORESCP');

  test('C-ECHO → qrscp', () => expectEcho(qrscp()), skip: qr);

  test('C-STORE → storescp, which writes the file', () async {
    final before = filesIn(env['INTEROP_PYSTORESCP_DIR']!).length;
    await expectStore(storescp(), _fixture);
    expect(filesIn(env['INTEROP_PYSTORESCP_DIR']!), hasLength(before + 1));
  }, skip: store);

  test('C-FIND → qrscp', () => expectFind(qrscp()), skip: qr);

  test('C-GET → qrscp', () => expectGet(qrscp()), skip: qr);

  test('C-MOVE → qrscp, into our StorageScp',
      () => expectMove(qrscp(), mover: 'QRSCP'),
      skip: qr);

  test('storescu → our StorageScp', () async {
    final stored = await storedBy(
        'PYSTORESCU',
        (port) => Process.run(env['INTEROP_PYTHON']!, [
              '-m', 'pynetdicom', 'storescu', //
              '127.0.0.1', '$port', _fixture,
              '-aet', 'PYSTORESCU', '-aec', ourAeTitle,
            ]));
    expect(stored, hasLength(1));
    expect(stored.single.sourceAeTitle, 'PYSTORESCU');
    expect(stored.single.sopClassUid, SopClasses.ctImageStorage);
  }, skip: store);
}
