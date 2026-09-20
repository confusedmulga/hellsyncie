import 'dart:typed_data';

import 'hlc.dart';

/// A CRDT operation — the decoded meaning of an [Op] payload.
///
/// Sealed so the engine's switch stays exhaustive: adding a variant (SetAdd,
/// ListInsert, …) forces every consumer to handle it. Slice 2a defines one
/// variant, [MapPut].
sealed class Operation {
  const Operation();
}

/// Set a field in a document's LWW-register map. The register with the greatest
/// [hlc] wins.
class MapPut extends Operation {
  const MapPut({
    required this.docId,
    required this.field,
    required this.value,
    required this.hlc,
  });

  final String docId;
  final String field;
  final Uint8List value;
  final Hlc hlc;

  @override
  String toString() => 'MapPut($docId.$field <- ${value.length} B @ $hlc)';
}
