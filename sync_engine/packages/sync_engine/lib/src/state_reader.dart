import 'dart:typed_data';

import 'crdt/rga.dart';

/// Read access to merged state: every document's LWW fields, OR-sets, and RGA
/// lists. Implemented by `CrdtState` and `SyncClient`.
///
/// Values are opaque bytes; give them a type with a `ValueCodec` (see
/// `Document`). All name lists are sorted.
abstract interface class StateReader {
  /// Every document with any field, set, or list.
  List<String> get docIds;

  /// Fields of [docId] ever set.
  List<String> fieldNames(String docId);

  /// The winning value of [field], or null if it was never set.
  Uint8List? fieldValue(String docId, String field);

  /// OR-sets of [docId], including ones now empty.
  List<String> setNames(String docId);

  /// Elements present in the set, sorted by bytes.
  List<Uint8List> setElements(String docId, String setField);

  bool setContains(String docId, String setField, Uint8List element);

  /// Lists of [docId], including ones now empty.
  List<String> listNames(String docId);

  /// Visible elements of the list, in order, with their stable ids.
  List<ListEntry> listEntries(String docId, String listField);
}
