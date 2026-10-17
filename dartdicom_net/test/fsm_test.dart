// The state machine table (PS3.8 Table 9-10): the requestor's rows so far.
import 'package:dartdicom_net/src/fsm/table.dart';
import 'package:test/test.dart';

void main() {
  test('the full PS3.8 vocabulary: 13 states, 19 events', () {
    expect(UlState.values, hasLength(13));
    expect(UlEvent.values, hasLength(19));
  });

  test('the requestor path: associate, transfer, release', () {
    var state = UlState.sta1;
    UlAction step(UlEvent e) {
      final (action, next) = transition(state, e);
      state = next;
      return action;
    }

    expect(step(UlEvent.evt1), UlAction.ae1);
    expect(step(UlEvent.evt2), UlAction.ae2);
    expect(step(UlEvent.evt3), UlAction.ae3);
    expect(state, UlState.sta6);
    expect(step(UlEvent.evt9), UlAction.dt1);
    expect(step(UlEvent.evt10), UlAction.dt2);
    expect(step(UlEvent.evt11), UlAction.ar1);
    expect(step(UlEvent.evt10), UlAction.ar6);
    expect(step(UlEvent.evt13), UlAction.ar3);
    expect(state, UlState.sta1);
  });

  test('a rejection returns to idle', () {
    expect(
        transition(UlState.sta5, UlEvent.evt4), (UlAction.ae4, UlState.sta1));
  });

  test('aborts: local (AA-1), peer (AA-3), lost transport (AA-4)', () {
    for (final s in [UlState.sta5, UlState.sta6, UlState.sta7]) {
      expect(transition(s, UlEvent.evt15), (UlAction.aa1, UlState.sta13));
      expect(transition(s, UlEvent.evt16), (UlAction.aa3, UlState.sta1));
      expect(transition(s, UlEvent.evt17), (UlAction.aa4, UlState.sta1));
      expect(transition(s, UlEvent.evt19), (UlAction.aa8, UlState.sta13));
    }
  });

  test('an unexpected PDU is AA-8 (e.g. A-ASSOCIATE-AC in Sta6)', () {
    expect(
        transition(UlState.sta6, UlEvent.evt3), (UlAction.aa8, UlState.sta13));
  });

  test('Sta13 ignores PDUs until the transport closes', () {
    expect(transition(UlState.sta13, UlEvent.evt10),
        (UlAction.aa6, UlState.sta13));
    expect(
        transition(UlState.sta13, UlEvent.evt17), (UlAction.ar5, UlState.sta1));
  });

  test('local requests the table does not define are absent', () {
    expect(transitions[(UlState.sta1, UlEvent.evt9)], isNull);
  });
}
