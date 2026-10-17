import 'dart:typed_data';

import 'bytes.dart';

// The variable items of A-ASSOCIATE-RQ/AC (PS3.8 §9.3.2–9.3.3, PS3.7 Annex D).

/// The DICOM Application Context Name, the only one there is.
const dicomApplicationContext = '1.2.840.10008.3.1.1.1';

/// A proposed presentation context (item 0x20): one abstract syntax and the
/// transfer syntaxes the requestor offers for it.
final class ProposedContext {
  const ProposedContext(this.id, this.abstractSyntax, this.transferSyntaxes);

  /// An odd number, 1–255.
  final int id;
  final String abstractSyntax;
  final List<String> transferSyntaxes;

  void encode(PduWriter w) => w.item(0x20, (b) {
        b
          ..u8(id)
          ..zeros(3)
          ..item(0x30, (s) => s.ascii(abstractSyntax));
        for (final ts in transferSyntaxes) {
          b.item(0x40, (s) => s.ascii(ts));
        }
      });

  static ProposedContext decode(PduReader r, int end) {
    final id = r.u8();
    r.skip(3);
    var abstractSyntax = '';
    final transferSyntaxes = <String>[];
    while (r.at < end) {
      final type = r.u8();
      r.skip(1);
      final length = r.u16();
      switch (type) {
        case 0x30:
          abstractSyntax = r.text(length);
        case 0x40:
          transferSyntaxes.add(r.text(length));
        default:
          r.skip(length);
      }
    }
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

  void encode(PduWriter w) => w.item(0x21, (b) {
        b
          ..u8(id)
          ..u8(0)
          ..u8(result)
          ..u8(0)
          ..item(0x40, (s) => s.ascii(transferSyntax));
      });

  static ContextResult decode(PduReader r, int end) {
    final id = r.u8();
    r.skip(1);
    final result = r.u8();
    r.skip(1);
    var ts = '';
    while (r.at < end) {
      final type = r.u8();
      r.skip(1);
      final length = r.u16();
      if (type == 0x40) {
        ts = r.text(length);
      } else {
        r.skip(length);
      }
    }
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
}

/// The User Information item (0x50).
final class UserInformation {
  const UserInformation({
    required this.maxLength,
    required this.implementationClassUid,
    this.implementationVersionName,
    this.roles = const [],
    this.otherItems = const [],
  });

  /// The largest P-DATA-TF the sender can receive; 0 means no limit.
  final int maxLength;
  final String implementationClassUid;
  final String? implementationVersionName;
  final List<RoleSelection> roles;

  /// Sub-items this version doesn't interpret (e.g. 0x53, 0x56, 0x58),
  /// kept as `(type, body)` so nothing is silently dropped.
  final List<(int, Uint8List)> otherItems;

  // pynetdicom's order: 51, 52, 55, then the 54 role items (I-12).
  void encode(PduWriter w) => w.item(0x50, (b) {
        b
          ..item(0x51, (s) => s.u32(maxLength))
          ..item(0x52, (s) => s.ascii(implementationClassUid));
        if (implementationVersionName != null) {
          b.item(0x55, (s) => s.ascii(implementationVersionName!));
        }
        for (final role in roles) {
          b.item(0x54, (s) {
            s
              ..u16(role.sopClass.length)
              ..ascii(role.sopClass)
              ..u8(role.scu ? 1 : 0)
              ..u8(role.scp ? 1 : 0);
          });
        }
        for (final (type, body) in otherItems) {
          b.item(type, (s) => s.bytes(body));
        }
      });

  static UserInformation decode(PduReader r, int end) {
    var maxLength = 0;
    var implementationClassUid = '';
    String? versionName;
    final roles = <RoleSelection>[];
    final others = <(int, Uint8List)>[];
    while (r.at < end) {
      final type = r.u8();
      r.skip(1);
      final length = r.u16();
      final itemEnd = r.at + length;
      switch (type) {
        case 0x51:
          maxLength = r.u32();
        case 0x52:
          implementationClassUid = r.text(length);
        case 0x55:
          versionName = r.text(length);
        case 0x54:
          final uidLength = r.u16();
          roles.add(RoleSelection(r.text(uidLength),
              scu: r.u8() == 1, scp: r.u8() == 1));
        default:
          others.add((type, Uint8List.fromList(r.take(length))));
      }
      r.at = itemEnd;
    }
    return UserInformation(
        maxLength: maxLength,
        implementationClassUid: implementationClassUid,
        implementationVersionName: versionName,
        roles: roles,
        otherItems: others);
  }
}
