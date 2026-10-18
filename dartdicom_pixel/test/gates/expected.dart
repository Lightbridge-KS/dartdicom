// The corpus files the pixel gate expects to fail, each with its reason.
// The gate fails if an unlisted file fails or a listed one passes, so this
// list only shrinks (docs/progress/overview-v0.md).

/// pydicom-data files whose pixels still disagree with pydicom's.
const pixelCorpusExpectedFailures = <({String file, String reason})>[
  (
    file: 'data_store/data/SC_ybr_full_uncompressed.dcm',
    reason: "YBR_FULL: pydicom's pixel_array converts it to RGB (as_rgb), "
        'and dartdicom returns the stored YBR values; color conversion is '
        'X-08 (P2).',
  ),
];
