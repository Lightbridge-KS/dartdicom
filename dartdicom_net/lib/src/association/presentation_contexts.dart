import 'package:dartdicom/dartdicom.dart';

/// A presentation context to propose: an abstract syntax (a SOP class) and
/// the transfer syntaxes offered for it, in order of preference.
///
/// By default only uncompressed syntaxes are offered (PRD N-03), so the
/// PACS decompresses and every instance decodes without a codec.
final class PresentationContext {
  const PresentationContext(this.abstractSyntax,
      {this.transferSyntaxes = uncompressed});

  /// Explicit VR Little Endian, then Implicit VR Little Endian (which every
  /// peer must support).
  static const uncompressed = [
    TransferSyntaxes.explicitVrLittleEndian,
    TransferSyntaxes.implicitVrLittleEndian,
  ];

  final Uid abstractSyntax;
  final List<Uid> transferSyntaxes;
}

/// A query/retrieve information model: which hierarchy a query walks
/// (PS3.4 §C.3), and its SOP classes for each operation.
enum QueryRetrieveModel {
  /// Patient → Study → Series → Image.
  patientRoot(
      SopClasses.patientRootQueryRetrieveInformationModelFind,
      SopClasses.patientRootQueryRetrieveInformationModelGet,
      SopClasses.patientRootQueryRetrieveInformationModelMove),

  /// Study → Series → Image.
  studyRoot(
      SopClasses.studyRootQueryRetrieveInformationModelFind,
      SopClasses.studyRootQueryRetrieveInformationModelGet,
      SopClasses.studyRootQueryRetrieveInformationModelMove);

  const QueryRetrieveModel(this.find, this.get, this.move);

  /// The C-FIND SOP class.
  final Uid find;

  /// The C-GET SOP class.
  final Uid get;

  /// The C-MOVE SOP class.
  final Uid move;
}

/// Ready-made context lists for `ApplicationEntity.requestedContexts`
/// (surface S2).
abstract final class PresentationContexts {
  /// C-ECHO.
  static const verification = [PresentationContext(SopClasses.verification)];

  /// C-FIND, C-GET and C-MOVE in the Study Root model.
  static const studyRootQueryRetrieve = [
    PresentationContext(SopClasses.studyRootQueryRetrieveInformationModelFind),
    PresentationContext(SopClasses.studyRootQueryRetrieveInformationModelGet),
    PresentationContext(SopClasses.studyRootQueryRetrieveInformationModelMove),
  ];

  /// C-FIND, C-GET and C-MOVE in the Patient Root model.
  static const patientRootQueryRetrieve = [
    PresentationContext(
        SopClasses.patientRootQueryRetrieveInformationModelFind),
    PresentationContext(SopClasses.patientRootQueryRetrieveInformationModelGet),
    PresentationContext(
        SopClasses.patientRootQueryRetrieveInformationModelMove),
  ];
}
