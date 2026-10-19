import '../bytes.dart';
import 'identifiers.dart';

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
