// The state machine table (PS3.8 Table 9-10), cell by cell (I-13): each of
// the 19 × 13 (state, event) pairs is what pynetdicom's table says, filled
// or blank (fixtures/data/net/transition_table.json).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartdicom_net/src/fsm/table.dart';
import 'package:test/test.dart';

void main() {
  final reference = (jsonDecode(
          File('../fixtures/data/net/transition_table.json').readAsStringSync())
      as Map<String, Object?>);

  test('the full PS3.8 vocabulary: 13 states, 19 events, 28 actions', () {
    expect(UlState.values, hasLength(13));
    expect(UlEvent.values, hasLength(19));
    expect(UlAction.values, hasLength(28));
  });

  test('every one of the 247 cells matches PS3.8 (I-13)', () {
    final mismatches = <String>[];
    var filled = 0;
    for (final state in UlState.values) {
      final row =
          (reference['Sta${state.index + 1}'] as Map<String, Object?>?) ??
              const {};
      for (final event in UlEvent.values) {
        final expected = row['Evt${event.index + 1}'] as List<Object?>?;
        final ours = transition(state, event);
        final at = '${state.name} + ${event.name}';
        if (expected == null) {
          if (ours != null) mismatches.add('$at: blank in PS3.8, ours $ours');
          continue;
        }
        filled++;
        final [action as String, next] = expected;
        if (ours == null) {
          mismatches.add('$at: PS3.8 $action, ours blank');
          continue;
        }
        final (ourAction, ourNext) = ours;
        if (_name(ourAction.name) != action) {
          mismatches.add('$at: PS3.8 $action, ours ${ourAction.name}');
        }
        // AE-6 and AR-8 choose between two next states when they run.
        final allowed = next is List ? next.cast<String>() : [next as String];
        if (!allowed.contains('Sta${ourNext.index + 1}')) {
          mismatches.add('$at: PS3.8 → $allowed, ours → ${ourNext.name}');
        }
      }
    }
    expect(mismatches, isEmpty);
    expect(filled, 123);
    expect(transitions, hasLength(123));
  });

  test(
      'the conditional cells take the usual branch (AE-6 → Sta3, '
      'AR-8 → Sta9 for the requestor)', () {
    expect(
        transition(UlState.sta2, UlEvent.evt6), (UlAction.ae6, UlState.sta3));
    expect(
        transition(UlState.sta7, UlEvent.evt12), (UlAction.ar8, UlState.sta9));
  });

  test(
      'Sta13 aborts a new request or an invalid PDU (AA-7), and ignores '
      'the rest until the transport closes', () {
    expect(
        transition(UlState.sta13, UlEvent.evt6), (UlAction.aa7, UlState.sta13));
    expect(transition(UlState.sta13, UlEvent.evt19),
        (UlAction.aa7, UlState.sta13));
    expect(transition(UlState.sta13, UlEvent.evt10),
        (UlAction.aa6, UlState.sta13));
    expect(
        transition(UlState.sta13, UlEvent.evt17), (UlAction.ar5, UlState.sta1));
  });
}

/// `ae1` → `AE-1`.
String _name(String action) =>
    '${action.substring(0, 2).toUpperCase()}-${action.substring(2)}';
