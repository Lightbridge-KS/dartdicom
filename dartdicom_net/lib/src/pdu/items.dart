import 'dart:typed_data';

import 'bytes.dart';

// The variable items of A-ASSOCIATE-RQ/AC (PS3.8 §9.3.2–9.3.3, PS3.7 Annex D).

/// The DICOM Application Context Name, the only one there is.
const dicomApplicationContext = '1.2.840.10008.3.1.1.1';

/// The item types of A-ASSOCIATE-RQ/AC, named as in PS3.8 §9.3 and PS3.7
/// Annex D.
abstract final class ItemType {
  /// Application Context Item (10H).
  static const applicationContext = 0x10;

  /// Presentation Context Item, as proposed in A-ASSOCIATE-RQ (20H).
  static const presentationContextRq = 0x20;

  /// Presentation Context Item, as answered in A-ASSOCIATE-AC (21H).
  static const presentationContextAc = 0x21;

  /// Abstract Syntax Sub-Item (30H).
  static const abstractSyntax = 0x30;

  /// Transfer Syntax Sub-Item (40H).
  static const transferSyntax = 0x40;

  /// User Information Item (50H).
  static const userInformation = 0x50;

  /// Maximum Length Sub-Item (51H).
  static const maxLength = 0x51;

  /// Implementation Class UID Sub-Item (52H).
  static const implementationClassUid = 0x52;

  /// Asynchronous Operations Window Sub-Item (53H).
  static const asyncOperationsWindow = 0x53;

  /// SCP/SCU Role Selection Sub-Item (54H).
  static const roleSelection = 0x54;

  /// Implementation Version Name Sub-Item (55H).
  static const implementationVersionName = 0x55;
}

/// A proposed presentation context (item 0x20): one abstract syntax and the
/// transfer syntaxes the requestor offers for it.
final class ProposedContext {
  const ProposedContext(this.id, this.abstractSyntax, this.transferSyntaxes);

  /// An odd number, 1–255.
  final int id;
  final String abstractSyntax;
  final List<String> transferSyntaxes;

  void encode(PduWriter w) => w.item(ItemType.presentationContextRq, (b) {
        b
          ..u8(id)
          ..zeros(3)
          ..item(ItemType.abstractSyntax, (s) => s.ascii(abstractSyntax));
        for (final ts in transferSyntaxes) {
          b.item(ItemType.transferSyntax, (s) => s.ascii(ts));
        }
      });

  static ProposedContext decode(PduReader r, int end) {
    final id = r.u8();
    r.skip(3);
    var abstractSyntax = '';
    final transferSyntaxes = <String>[];
    r.items(end, (type, itemEnd) {
      switch (type) {
        case ItemType.abstractSyntax:
          abstractSyntax = r.text(itemEnd - r.at);
        case ItemType.transferSyntax:
          transferSyntaxes.add(r.text(itemEnd - r.at));
      }
    });
    return ProposedContext(id, abstractSyntax, transferSyntaxes);
  }
}

/// The acceptor's answer for one presentation context (item 0x21).
final class ContextResult {
  const ContextResult(this.id, this.result, this.transferSyntax);

  final int id;

  /// 0 acceptance, 1 user rejection, 2 no reason, 3 abstract syntax not
  /// supported, 4 transfer syntaxes not supported.
  final int result;

  /// The accepted transfer syntax; meaningless unless [result] is 0.
  final String transferSyntax;

  bool get accepted => result == 0;

  void encode(PduWriter w) => w.item(ItemType.presentationContextAc, (b) {
        b
          ..u8(id)
          ..u8(0)
          ..u8(result)
          ..u8(0)
          ..item(ItemType.transferSyntax, (s) => s.ascii(transferSyntax));
      });

  static ContextResult decode(PduReader r, int end) {
    final id = r.u8();
    r.skip(1);
    final result = r.u8();
    r.skip(1);
    var ts = '';
    r.items(end, (type, itemEnd) {
      if (type == ItemType.transferSyntax) ts = r.text(itemEnd - r.at);
    });
    return ContextResult(id, result, ts);
  }
}

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
    this.implementationVersionName,
    this.roles = const [],
    this.asyncWindow,
    this.otherItems = const [],
  });

  /// The largest P-DATA-TF the sender can receive; 0 means no limit.
  final int maxLength;
  final String implementationClassUid;
  final String? implementationVersionName;
  final List<RoleSelection> roles;
  final AsyncOperationsWindow? asyncWindow;

  /// Sub-items this version doesn't interpret (e.g. 0x56, 0x58),
  /// kept as `(type, body)` so nothing is silently dropped.
  final List<(int, Uint8List)> otherItems;

  // pynetdicom's order: 51, 52, 55, the 54 role items, then 53 (I-12).
  void encode(PduWriter w) => w.item(ItemType.userInformation, (b) {
        b
          ..item(ItemType.maxLength, (s) => s.u32(maxLength))
          ..item(ItemType.implementationClassUid,
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
    var implementationClassUid = '';
    String? versionName;
    final roles = <RoleSelection>[];
    AsyncOperationsWindow? window;
    final others = <(int, Uint8List)>[];
    r.items(end, (type, itemEnd) {
      switch (type) {
        case ItemType.maxLength:
          maxLength = r.u32();
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
        implementationClassUid: implementationClassUid,
        implementationVersionName: versionName,
        roles: roles,
        asyncWindow: window,
        otherItems: others);
  }
}
