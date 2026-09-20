import 'dart:typed_data';

import 'hlc.dart';

/// A CRDT operation — the decoded meaning of an [Op] payload.
///
/// Sealed so the engine's switch stays exhaustive: adding a variant forces
/// every consumer to handle it.
sealed class Operation {
  const Operation();
}

/// Set a field in a document's LWW-register map. The register with the greatest
/// [hlc] wins. (Slice 2a.)
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

/// Add [element] to an OR-set, stamped with a globally-unique [tag] (an HLC).
/// (Slice 2b.)
class SetAdd extends Operation {
  const SetAdd({
    required this.docId,
    required this.setField,
    required this.element,
    required this.tag,
  });

  final String docId;
  final String setField;
  final Uint8List element;
  final Hlc tag;

  @override
  String toString() => 'SetAdd($docId.$setField += ${element.length} B @ $tag)';
}

/// Remove [element] from an OR-set by cancelling the add-tags the remover had
/// OBSERVED. Concurrent adds with unobserved tags survive (add-wins). (2b.)
class SetRemove extends Operation {
  const SetRemove({
    required this.docId,
    required this.setField,
    required this.element,
    required this.observedTags,
  });

  final String docId;
  final String setField;
  final Uint8List element;
  final List<Hlc> observedTags;

  @override
  String toString() => 'SetRemove($docId.$setField -= ${element.length} B, '
      '${observedTags.length} tags)';
}
