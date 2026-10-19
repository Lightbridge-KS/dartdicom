part of 'pdu.dart';

/// P-DATA-TF (type 0x04): one or more PDVs.
final class PDataTf extends Pdu {
  const PDataTf(this.pdvs);

  final List<Pdv> pdvs;

  @override
  String get summary => 'P-DATA-TF ${[
        for (final p in pdvs)
          'ctx ${p.contextId} ${p.isCommand ? 'command' : 'dataset'}'
              '${p.isLast ? ' last' : ''} ${p.data.length} B',
      ].join(', ')}';

  @override
  int get type => 0x04;

  @override
  void encodeBody(PduWriter w) {
    for (final pdv in pdvs) {
      pdv.encode(w);
    }
  }

  static PDataTf _decode(PduReader r) {
    final pdvs = <Pdv>[];
    while (!r.done) {
      pdvs.add(Pdv.decode(r));
    }
    return PDataTf(pdvs);
  }

  @override
  String toString() => 'P-DATA-TF(${pdvs.length} PDVs)';
}
