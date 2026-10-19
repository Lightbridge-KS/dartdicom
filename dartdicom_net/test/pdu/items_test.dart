import 'dart:typed_data';

import 'package:dartdicom_net/src/pdu/bytes.dart';
import 'package:dartdicom_net/src/pdu/items.dart';
import 'package:dartdicom_net/src/pdu/items/identifiers.dart' as identifiers;
import 'package:dartdicom_net/src/pdu/items/presentation_context.dart'
    as contexts;
import 'package:dartdicom_net/src/pdu/items/user_information.dart'
    as information;
import 'package:test/test.dart';

Uint8List _items(void Function(PduWriter) write) {
  final w = PduWriter();
  write(w);
  return w.take();
}

UserInformation _decode(Uint8List bytes) =>
    UserInformation.decode(PduReader(bytes), bytes.length);

void main() {
  test('item barrel forwards type and constructor identity', () {
    for (final pair in <(Object, Object)>[
      (ItemType, identifiers.ItemType),
      (ProposedContext, contexts.ProposedContext),
      (ContextResult, contexts.ContextResult),
      (RoleSelection, information.RoleSelection),
      (AsyncOperationsWindow, information.AsyncOperationsWindow),
      (UserInformation, information.UserInformation),
      (ProposedContext.new, contexts.ProposedContext.new),
      (ContextResult.new, contexts.ContextResult.new),
      (RoleSelection.new, information.RoleSelection.new),
      (AsyncOperationsWindow.new, information.AsyncOperationsWindow.new),
      (UserInformation.new, information.UserInformation.new),
      (dicomApplicationContext, identifiers.dicomApplicationContext),
      (
        const ProposedContext(1, '1', ['2']),
        const contexts.ProposedContext(1, '1', ['2'])
      ),
      (const ContextResult(1, 0, '2'), const contexts.ContextResult(1, 0, '2')),
      (
        const RoleSelection('1', scu: true, scp: false),
        const information.RoleSelection('1', scu: true, scp: false)
      ),
      (
        const AsyncOperationsWindow(invoked: 1, performed: 2),
        const information.AsyncOperationsWindow(invoked: 1, performed: 2)
      ),
      (
        const UserInformation(maxLength: 1, implementationClassUid: '1'),
        const information.UserInformation(
            maxLength: 1, implementationClassUid: '1')
      ),
    ]) {
      expect(identical(pair.$1, pair.$2), isTrue);
    }
  });
  group('item boundaries', () {
    for (final (name, body) in [
      ('maximum length', [0x51, 0, 0, 1, 0]),
      ('async window', [0x53, 0, 0, 1, 0]),
      ('role flags', [0x54, 0, 0, 4, 0, 1, 0x31, 1]),
      ('role UID', [0x54, 0, 0, 2, 0, 5]),
    ]) {
      test('$name cannot borrow the next sub-item', () {
        final bytes = Uint8List.fromList([
          ...body,
          0x52,
          0,
          0,
          3,
          0x31,
          0x2e,
          0x32,
        ]);
        expect(() => _decode(bytes), throwsFormatException);
      });
    }
    test('overread fails before visiting a sibling', () {
      final r = PduReader(Uint8List.fromList([1, 0, 0, 0, 2, 0, 0, 0]));
      final visited = <int>[];
      expect(
          () => r.items(r.end, (type, end) {
                visited.add(type);
                r.u8();
              }),
          throwsFormatException);
      expect(visited, [1]);
    });
    test('unread bodies are skipped and exact reads reach the next item', () {
      final r = PduReader(Uint8List.fromList([1, 0, 0, 1, 9, 2, 0, 0, 1, 8]));
      final visited = <int>[];
      r.items(r.end, (type, end) {
        visited.add(type);
        if (type == 2) expect(r.u8(), 8);
      });
      expect(visited, [1, 2]);
      expect(r.done, isTrue);
    });
  });

  test('user information preserves ordering and constructor-owned data', () {
    final roles = <RoleSelection>[];
    final payload = Uint8List.fromList([7]);
    final others = <(int, Uint8List)>[(0x58, payload)];
    final info = UserInformation(
        maxLength: 17,
        implementationClassUid: '1.2',
        implementationVersionName: 'TEST',
        roles: roles,
        asyncWindow: const AsyncOperationsWindow(invoked: 2, performed: 3),
        otherItems: others);
    roles.add(const RoleSelection('1.3', scu: true, scp: false));
    payload[0] = 8;
    final encoded = _items(info.encode);
    final r = PduReader(encoded, 4);
    final types = <int>[];
    r.items(r.end, (type, end) => types.add(type));
    expect(types, [0x51, 0x52, 0x55, 0x54, 0x53, 0x58]);
    expect(identical(info.roles, roles), isTrue);
    expect(identical(info.otherItems, others), isTrue);
    final decoded = _decode(Uint8List.sublistView(encoded, 4));
    expect(decoded.otherItems.single.$2, [8]);
    expect(decoded.asyncWindow!.performed, 3);
    expect(decoded.roles.single.scu, isTrue);
  });

  test('missing and explicit zero maximum length remain distinct', () {
    expect(_decode(Uint8List(0)).hasMaxLength, isFalse);
    final explicit = _decode(_items((w) => w.item(0x51, (b) => b.u32(0))));
    expect(explicit.hasMaxLength, isTrue);
    expect(explicit.maxLength, 0);
    final w = _items(const UserInformation(
            maxLength: 0, hasMaxLength: false, implementationClassUid: '1')
        .encode);
    expect(w[4], 0x52);
  });

  test('duplicate fields use last value, repeated roles and unknowns append',
      () {
    final bytes = _items((w) {
      for (var i = 1; i <= 2; i++) {
        w.item(0x51, (b) => b.u32(i));
        w.item(0x52, (b) => b.ascii('1.$i'));
        w.item(0x55, (b) => b.ascii('V$i'));
        RoleSelection('1.$i', scu: true, scp: false).encode(w);
        AsyncOperationsWindow(invoked: i, performed: i + 1).encode(w);
        w.item(0x58, (b) => b.u8(i));
      }
    });
    final info = _decode(bytes);
    expect(info.maxLength, 2);
    expect(info.implementationClassUid, '1.2');
    expect(info.implementationVersionName, 'V2');
    expect(info.asyncWindow!.invoked, 2);
    expect(info.roles.map((r) => r.sopClass), ['1.1', '1.2']);
    expect(info.otherItems.map((r) => r.$2.single), [1, 2]);
    bytes.fillRange(0, bytes.length, 0);
    expect(info.otherItems.map((r) => r.$2.single), [1, 2]);
  });

  test('presentation contexts retain duplicate and unknown-item handling', () {
    final body = _items((w) {
      w
        ..u8(3)
        ..zeros(3);
      w.item(0x30, (b) => b.ascii('1'));
      w.item(0x40, (b) => b.ascii('2'));
      w.item(0x59, (b) => b.u8(9));
      w.item(0x30, (b) => b.ascii('3'));
      w.item(0x40, (b) => b.ascii('4'));
    });
    final proposed = ProposedContext.decode(PduReader(body), body.length);
    expect(proposed.id, 3);
    expect(proposed.abstractSyntax, '3');
    expect(proposed.transferSyntaxes, ['2', '4']);
    final result = ContextResult.decode(PduReader(body), body.length);
    expect(result.accepted, isTrue);
    expect(result.transferSyntax, '4');
    final syntaxes = <String>['2'];
    final context = ProposedContext(1, '1', syntaxes);
    syntaxes.add('3');
    expect(identical(context.transferSyntaxes, syntaxes), isTrue);
    expect(_items(context.encode), [
      0x20,
      0,
      0,
      19,
      1,
      0,
      0,
      0,
      0x30,
      0,
      0,
      1,
      49,
      0x40,
      0,
      0,
      1,
      50,
      0x40,
      0,
      0,
      1,
      51
    ]);
  });

  test('role flags retain non-one-as-false decoding', () {
    final role =
        RoleSelection.decode(PduReader(Uint8List.fromList([0, 1, 49, 2, 1])));
    expect(role.scu, isFalse);
    expect(role.scp, isTrue);
  });
}
