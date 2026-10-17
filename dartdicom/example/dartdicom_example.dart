import 'package:dartdicom/dartdicom.dart';

// Builds a dataset in memory, encodes it, and reads it back. It runs on
// every platform; CI also compiles it to Wasm, so the parser and writer must
// build there.
void main() {
  final query = Dataset()
    ..set(DicomTags.queryRetrieveLevel, 'STUDY')
    ..set(DicomTags.patientId, 'P001')
    ..setAll(DicomTags.windowCenter, [40.0, -600.0])
    ..setEmpty(DicomTags.studyInstanceUid);

  final bytes =
      query.toBytes(transferSyntax: TransferSyntaxes.explicitVrLittleEndian);
  final back = Dataset.fromBytes(bytes,
      transferSyntax: TransferSyntaxes.explicitVrLittleEndian);

  print('$back in ${bytes.length} bytes');
  print('level: ${back.get(DicomTags.queryRetrieveLevel)}');
  print('window centers: ${back.getAll(DicomTags.windowCenter)}');
}
