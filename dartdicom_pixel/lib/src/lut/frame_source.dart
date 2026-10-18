import 'package:dartdicom/dartdicom.dart';

import '../errors.dart';

/// Where frame [frame]'s [macro] attributes come from (blueprint F44): the
/// macro's item in the frame's Per-Frame Functional Groups item, else in
/// the Shared Functional Groups item, else [ds]'s top level, for images
/// that have no functional groups.
///
/// A whole item wins: its attributes replace the top level's, and nothing
/// mixes across levels (the Pixel Value Transformation item's Rescale
/// Slope never meets a top-level Rescale Intercept).
Dataset frameSource(Dataset ds, int frame, One<Sequence> macro) {
  Dataset? itemOf(One<Sequence> groups, int index) {
    final Sequence? items;
    try {
      items = ds.get(groups);
    } on DicomDataException {
      throw InvalidPixelModule(groups, 'cannot be read as a sequence');
    }
    if (items == null || index >= items.length) return null;
    final Sequence? macros;
    try {
      macros = items[index].get(macro);
    } on DicomDataException {
      throw InvalidPixelModule(macro, 'cannot be read as a sequence');
    }
    return macros == null || macros.isEmpty ? null : macros.first;
  }

  return itemOf(DicomTags.perFrameFunctionalGroupsSequence, frame) ??
      itemOf(DicomTags.sharedFunctionalGroupsSequence, 0) ??
      ds;
}
