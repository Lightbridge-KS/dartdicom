import 'dart:typed_data';

import '../bytes.dart';
import 'identifiers.dart';

/// SCP/SCU Role Selection (sub-item 0x54, PS3.7 §D.3.3.4): the roles the
/// requestor proposes, or the acceptor accepts, for one SOP class.
final class RoleSelection {
  const RoleSelection(this.sopClass, {required this.scu, required this.scp});

  final String sopClass;
  final bool scu;
  final bool scp;

  void encode(PduWriter w) => w.item(ItemType.roleSelection, (s) {
        s
          ..u16(sopClass.length)
          ..ascii(sopClass)
          ..u8(scu ? 1 : 0)
          ..u8(scp ? 1 : 0);
      });

  /// Decodes the body of a role selection sub-item.
  static RoleSelection decode(PduReader r) {
    final uidLength = r.u16();
    return RoleSelection(r.text(uidLength), scu: r.u8() == 1, scp: r.u8() == 1);
  }
}

/// Asynchronous Operations Window (sub-item 0x53, PS3.7 §D.3.3.3): how many
/// operations each side may have outstanding. dartdicom runs one at a time,
/// so it proposes none and answers (1, 1).
final class AsyncOperationsWindow {
  const AsyncOperationsWindow({required this.invoked, required this.performed});

  /// Maximum Number Operations Invoked.
  final int invoked;

  /// Maximum Number Operations Performed.
  final int performed;

  void encode(PduWriter w) => w.item(ItemType.asyncOperationsWindow, (s) {
        s
          ..u16(invoked)
          ..u16(performed);
      });

  static AsyncOperationsWindow decode(PduReader r) =>
      AsyncOperationsWindow(invoked: r.u16(), performed: r.u16());
}

/// The User Information item (0x50).
final class UserInformation {
  const UserInformation({
    required this.maxLength,
    required this.implementationClassUid,
    this.hasMaxLength = true,
    this.implementationVersionName,
    this.roles = const [],
    this.asyncWindow,
    this.otherItems = const [],
  });

  /// The largest P-DATA-TF the sender can receive; 0 means no limit.
  final int maxLength;

  /// Whether Max Length was actually present, independently of the networking
  /// fallback of zero for peers that omit it.
  final bool hasMaxLength;
  final String implementationClassUid;
  final String? implementationVersionName;
  final List<RoleSelection> roles;
  final AsyncOperationsWindow? asyncWindow;

  /// Sub-items this version doesn't interpret (e.g. 0x56, 0x58),
  /// kept as `(type, body)` so nothing is silently dropped.
  final List<(int, Uint8List)> otherItems;

  // pynetdicom's order: 51, 52, 55, the 54 role items, then 53 (I-12).
  void encode(PduWriter w) => w.item(ItemType.userInformation, (b) {
        if (hasMaxLength) {
          b.item(ItemType.maxLength, (s) => s.u32(maxLength));
        }
        b.item(ItemType.implementationClassUid,
            (s) => s.ascii(implementationClassUid));
        if (implementationVersionName != null) {
          b.item(ItemType.implementationVersionName,
              (s) => s.ascii(implementationVersionName!));
        }
        for (final role in roles) {
          role.encode(b);
        }
        asyncWindow?.encode(b);
        for (final (type, body) in otherItems) {
          b.item(type, (s) => s.bytes(body));
        }
      });

  static UserInformation decode(PduReader r, int end) {
    var maxLength = 0;
    var hasMaxLength = false;
    var implementationClassUid = '';
    String? versionName;
    final roles = <RoleSelection>[];
    AsyncOperationsWindow? window;
    final others = <(int, Uint8List)>[];
    r.items(end, (type, itemEnd) {
      switch (type) {
        case ItemType.maxLength:
          maxLength = r.u32();
          hasMaxLength = true;
        case ItemType.implementationClassUid:
          implementationClassUid = r.text(itemEnd - r.at);
        case ItemType.implementationVersionName:
          versionName = r.text(itemEnd - r.at);
        case ItemType.roleSelection:
          roles.add(RoleSelection.decode(r));
        case ItemType.asyncOperationsWindow:
          window = AsyncOperationsWindow.decode(r);
        default:
          others.add((type, Uint8List.fromList(r.take(itemEnd - r.at))));
      }
    });
    return UserInformation(
        maxLength: maxLength,
        hasMaxLength: hasMaxLength,
        implementationClassUid: implementationClassUid,
        implementationVersionName: versionName,
        roles: roles,
        asyncWindow: window,
        otherItems: others);
  }
}
