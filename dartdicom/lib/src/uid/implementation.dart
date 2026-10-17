import 'uid.dart';

/// The Implementation Class UID that dartdicom writes into file meta
/// (0002,0012) and sends in A-ASSOCIATE (PS3.7 §D.3.3.2).
///
/// Fixed for the life of the project: `2.25.` + the name-based UUID (v5) of
/// the repository URL in the URL namespace.
const dartdicomImplementationClassUid =
    Uid('2.25.299813086794151582182948095029529220637');

/// The Implementation Version Name (0002,0013): `DARTDICOM` and the release
/// version, at most 16 characters (VR SH). A test ties it to `pubspec.yaml`.
const dartdicomImplementationVersionName = 'DARTDICOM 0.1.0';
