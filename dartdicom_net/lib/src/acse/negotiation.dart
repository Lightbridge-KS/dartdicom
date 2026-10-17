import 'package:dartdicom/dartdicom.dart';

import '../pdu/items.dart';
import '../pdu/pdus.dart';

// ACSE for the requestor (PS3.8 §7.1, PS3.7 Annex D): what to propose, and
// what the peer's answer means.

/// The A-ASSOCIATE-RQ from [callingAeTitle] to [calledAeTitle]: [contexts]
/// as `(abstract syntax, transfer syntaxes)` with odd IDs from 1, and a role
/// selection item for each of [scpRoleClasses] (to receive a C-GET's
/// C-STORE sub-operations, PS3.4 §C.4.3.3). A role item proposing SCP alone
/// would take away the SCU role (PS3.7 §D.3.3.4), so a class this side also
/// sends ([contexts] proposes it twice) gets both.
///
/// Throws an [ArgumentError] for more than 128 contexts or a bad AE title.
AssociateRq buildAssociateRq({
  required String callingAeTitle,
  required String calledAeTitle,
  required List<(Uid, List<Uid>)> contexts,
  required Iterable<Uid> scpRoleClasses,
  required int maxPduLength,
}) {
  _checkAeTitle(callingAeTitle, 'aeTitle');
  _checkAeTitle(calledAeTitle, 'calledAeTitle');
  if (contexts.length > 128) {
    throw ArgumentError.value(
        contexts.length,
        'requestedContexts',
        'an association allows at most 128 presentation contexts; '
            'propose fewer storage classes');
  }
  return AssociateRq(
    calledAeTitle: calledAeTitle,
    callingAeTitle: callingAeTitle,
    contexts: [
      for (final (i, (abstractSyntax, transferSyntaxes)) in contexts.indexed)
        ProposedContext(2 * i + 1, abstractSyntax.value,
            [for (final ts in transferSyntaxes) ts.value]),
    ],
    userInformation: UserInformation(
      maxLength: maxPduLength,
      implementationClassUid: dartdicomImplementationClassUid.value,
      implementationVersionName: dartdicomImplementationVersionName,
      roles: [
        for (final sopClass in {...scpRoleClasses})
          RoleSelection(sopClass.value,
              scu: contexts.where((c) => c.$1 == sopClass).length > 1,
              scp: true),
      ],
    ),
  );
}

/// The contexts of [rq] that [ac] accepted, mapped back by ID (an AC
/// carries no abstract syntax), with the roles this side holds on each: the
/// AC's role reply for its SOP class, or with none, the default roles (this
/// side SCU only, PS3.7 §D.3.3.4).
List<AcceptedContext> negotiatedContexts(AssociateRq rq, AssociateAc ac) {
  final proposed = {for (final c in rq.contexts) c.id: c};
  final roles = {
    for (final role in ac.userInformation.roles) role.sopClass: role,
  };
  return List.unmodifiable([
    for (final result in ac.results)
      if (proposed[result.id] case final p? when result.accepted)
        AcceptedContext(
            result.id, Uid(p.abstractSyntax), Uid(result.transferSyntax),
            scuRole: roles[p.abstractSyntax]?.scu ?? true,
            scpRole: roles[p.abstractSyntax]?.scp ?? false),
  ]);
}

void _checkAeTitle(String ae, String name) {
  if (ae.trim().isEmpty ||
      ae.length > 16 ||
      ae.codeUnits.any((c) => c < 0x20 || c > 0x7E || c == 0x5C)) {
    throw ArgumentError.value(
        ae, name, 'must be 1–16 printable ASCII characters, no backslash');
  }
}

/// One presentation context the peer accepted.
final class AcceptedContext {
  const AcceptedContext(this.id, this.abstractSyntax, this.transferSyntax,
      {this.scuRole = true, this.scpRole = false});

  /// The presentation context ID.
  final int id;

  /// The SOP class.
  final Uid abstractSyntax;

  /// The transfer syntax every dataset on this context is encoded in.
  final Uid transferSyntax;

  /// Whether this side may act as SCU for [abstractSyntax]: send its
  /// requests, such as C-STORE. The default role, unless role selection
  /// took it away.
  final bool scuRole;

  /// Whether this side may act as SCP for [abstractSyntax] (role selection
  /// accepted): needed to receive a C-GET's C-STORE sub-operations.
  final bool scpRole;

  @override
  String toString() =>
      'AcceptedContext($id, ${abstractSyntax.value}, ${transferSyntax.value}'
      '${scuRole ? '' : ', no SCU role'}${scpRole ? ', SCP role' : ''})';
}
