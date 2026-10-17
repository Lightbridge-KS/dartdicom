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
