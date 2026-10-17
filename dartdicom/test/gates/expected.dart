// The curated lists two gates read. Each entry must say why it is there:
// edit these to accept a known corpus failure, or a DCMTK message on a
// written file (blueprint §6).

/// pydicom-data files that still fail `corpus_test.dart`, each with the
/// reason and the step that fixes it. The test fails if an unlisted file
/// fails or a listed one passes, so this list only shrinks
/// (docs/progress/overview-v0.md).
const corpusExpectedFailures = <({String file, String reason})>[];

/// DCMTK messages the written-file gate (`written_test.dart`) allows beyond
/// those the source file already raises. [dcmtk] is a prefix of the
/// `dcmdump` version the entry applies to; [pattern] is a regex over one
/// message line.
const dcmdumpAllowlist = <({String dcmtk, String pattern, String reason})>[
  (
    dcmtk: '3',
    pattern: r'^W: (DcmItem: )?Found element '
        r'\([0-9a-f]{3}[13579bdf],[0-9a-f]{4}\) with VR ?=?UN and undefined '
        r'length, reading a sequence with transfer syntax '
        r'LittleEndianImplicit \(CP-246\)$',
    reason: 'A private sequence in Implicit VR has no VR on the wire; the '
        'writer gives it an undefined length so readers find its items, and '
        'DCMTK says it did (CP-246). DCMTK 3.6 (apt) words it without '
        '"DcmItem: ", and "VR UN" for 3.7\'s "VR=UN".',
  ),
];
