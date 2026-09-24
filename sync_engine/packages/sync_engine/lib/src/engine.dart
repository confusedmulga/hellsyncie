import 'dart:typed_data';

import 'op.dart';

/// Folds an op set into converged, rendered state.
///
/// Given a set of ops, an engine folds them — LWW-register maps, OR-sets, RGA
/// lists, HLC tie-breaks — into the materialized state. Applying the same op
/// set on any device, in any order, MUST yield byte-identical output.
/// `CrdtEngine` is the implementation.
abstract interface class SyncEngine {
  /// Fold [ops] into the converged materialized document bytes.
  Uint8List materialize(Iterable<Op> ops);
}
