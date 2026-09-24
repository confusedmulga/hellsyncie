import 'dart:typed_data';

import 'crdt_state.dart';
import 'engine.dart';
import 'hlc.dart';
import 'op.dart';

/// The CRDT merge engine: folds an op set into a [CrdtState] and renders it.
///
/// [materialize] is a pure, order-independent fold. Applying the same ops in
/// any order, with duplicates, yields byte-identical output. Long-lived
/// callers (the sync client) keep a [CrdtState] and update it incrementally
/// instead of re-folding.
class CrdtEngine implements SyncEngine {
  const CrdtEngine();

  /// Fold [ops] into a fresh state.
  static CrdtState fold(Iterable<Op> ops) {
    final state = CrdtState();
    ops.forEach(state.applyOp);
    return state;
  }

  @override
  Uint8List materialize(Iterable<Op> ops) => fold(ops).serialize();

  /// Every RGA element id ever inserted into one list across [ops], deleted
  /// ones included, ascending — candidates for an insert anchor or a delete.
  static List<Hlc> elementIds(
    Iterable<Op> ops,
    String docId,
    String listField,
  ) =>
      fold(ops).elementIds(docId, listField);

  /// The live (uncancelled) add-tags of one OR-set element across [ops] —
  /// what a `SetRemove` must observe to make the element absent.
  static List<Hlc> addTagsFor(
    Iterable<Op> ops,
    String docId,
    String setField,
    Uint8List element,
  ) =>
      fold(ops).addTagsFor(docId, setField, element);
}
