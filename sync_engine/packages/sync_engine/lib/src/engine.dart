import 'dart:typed_data';

import 'op.dart';

/// The seam the real CRDT engine slots into in a later build.
///
/// Given every op a device knows locally (after a transport pull), a concrete
/// engine folds them — LWW-register maps, OR-sets, RGA lists, HLC tie-breaks —
/// into the converged materialized state. Applying the same op set on any
/// device, in any order, MUST yield byte-identical output.
///
/// Not implemented yet. The simulation harness drives this stage by asserting
/// op-log set equality instead of merged-state equality; see the harness TODO.
abstract interface class SyncEngine {
  /// Fold [ops] into the converged materialized document bytes.
  Uint8List materialize(Iterable<Op> ops);
}
