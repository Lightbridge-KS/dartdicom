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
