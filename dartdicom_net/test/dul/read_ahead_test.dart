// The DUL's one-PDU hand-off between its reader and receive (blueprint
// F42).
import 'dart:typed_data';

import 'package:dartdicom_net/src/dul/read_ahead.dart';
import 'package:dartdicom_net/src/pdu/pdus.dart';
import 'package:test/test.dart';

final _pdu = PDataTf([
  Pdv(1, Uint8List.fromList([1, 2]), isCommand: true, isLast: true),
]);

void main() {
  test('take waits for a held PDU, and vacated for its taking', () async {
    final readAhead = ReadAhead();
    final taken = readAhead.take();
    readAhead.hold(_pdu);
    var vacated = false;
    final waiting = readAhead.vacated().then((_) => vacated = true);
    expect(await taken, same(_pdu));
    await waiting;
    expect(vacated, isTrue);
  });

  test('vacated waits while a PDU is held', () async {
    final readAhead = ReadAhead()..hold(_pdu);
    var vacated = false;
    final waiting = readAhead.vacated().then((_) => vacated = true);
    await pumpEventQueue();
    expect(vacated, isFalse);
    await readAhead.take();
    await waiting;
    expect(vacated, isTrue);
  });

  test('close wakes every waiter; take then answers null', () async {
    final readAhead = ReadAhead();
    final taken = readAhead.take();
    readAhead.close(drop: true);
    expect(await taken, isNull);
    expect(await readAhead.take(), isNull);
  });

  test('close keeps the held PDU for take unless it drops it', () async {
    final kept = ReadAhead()
      ..hold(_pdu)
      ..close(drop: false);
    await kept.vacated();
    expect(await kept.take(), same(_pdu));
    expect(await kept.take(), isNull);

    final dropped = ReadAhead()
      ..hold(_pdu)
      ..close(drop: true);
    expect(await dropped.take(), isNull);
  });
}
