import '../../dataset/element.dart';

/// One dataset level being read: what later elements need from earlier
/// ones, and the elements read so far (for settling ambiguous VRs once the
/// level is complete).
final class Level {
  Level({required this.explicit})
      : charset = const [],
        parent = null,
        depth = 0;

  /// An item's level: it starts from its sequence's state, and what it
  /// reads stays inside it.
  Level.item(Level this.parent, {required this.explicit})
      : charset = parent.charset,
        bitsAllocated = parent.bitsAllocated,
        pixelRepresentation = parent.pixelRepresentation,
        depth = parent.depth + 1;

  final Level? parent;
  final int depth;

  /// Whether this level is read as Explicit VR. It can differ from the
  /// transfer syntax: an item can be implicit, and UN→SQ items are.
  final bool explicit;
  List<String> charset;
  int? bitsAllocated;
  int? pixelRepresentation;
  final elements = <DataElement>[];
}
