import 'dart:convert';
import 'dart:typed_data';

import 'crdt/lww_register.dart';
import 'crdt/or_set.dart';
import 'engine.dart';
import 'hlc.dart';
import 'op.dart';
import 'operation.dart';
import 'operation_codec.dart';

/// The CRDT merge engine.
///
/// Slice 2a: LWW-register maps. Slice 2b: OR-sets (add-wins).
///
/// [materialize] is a pure, order-independent fold over the op set. Applying
/// the same ops in any order, with duplicates, yields byte-identical output.
class CrdtEngine implements SyncEngine {
  const CrdtEngine();

  @override
  Uint8List materialize(Iterable<Op> ops) {
    final lww = <String, Map<String, LwwRegister>>{}; // doc -> field -> reg
    final sets = <String, Map<String, OrSet>>{}; // doc -> setField -> OrSet

    for (final op in ops) {
      final Operation decoded;
      try {
        decoded = OperationCodec.decode(op.payload);
      } on FormatException {
        continue; // undecodable payload: skip, same as a corrupt op file
      }
      switch (decoded) {
        case final MapPut o:
          final fields =
              lww.putIfAbsent(o.docId, () => <String, LwwRegister>{});
          final incoming = LwwRegister(o.value, o.hlc);
          final cur = fields[o.field];
          fields[o.field] = cur == null ? incoming : cur.merge(incoming);
        case final SetAdd o:
          _setFor(sets, o.docId, o.setField).add(o.element, o.tag);
        case final SetRemove o:
          _setFor(sets, o.docId, o.setField).remove(o.element, o.observedTags);
      }
    }
    return _serialize(lww, sets);
  }

  static OrSet _setFor(
    Map<String, Map<String, OrSet>> sets,
    String docId,
    String setField,
  ) =>
      sets.putIfAbsent(docId, () => <String, OrSet>{}).putIfAbsent(
            setField,
            OrSet.new,
          );

  /// All add-tags for one element across [ops] — what a device folds to author
  /// a [SetRemove] that "observes" the element's current tags. Pure/static.
  static List<Hlc> addTagsFor(
    Iterable<Op> ops,
    String docId,
    String setField,
    Uint8List element,
  ) {
    final key = OrSet.keyOf(element);
    final tags = <Hlc>[];
    for (final op in ops) {
      final Operation decoded;
      try {
        decoded = OperationCodec.decode(op.payload);
      } on FormatException {
        continue;
      }
      if (decoded is SetAdd &&
          decoded.docId == docId &&
          decoded.setField == setField &&
          OrSet.keyOf(decoded.element) == key) {
        tags.add(decoded.tag);
      }
    }
    return tags;
  }

  /// Canonical, length-prefixed serialization. Length prefixes keep it
  /// unambiguous for any bytes; sorting makes it order-independent.
  Uint8List _serialize(
    Map<String, Map<String, LwwRegister>> lww,
    Map<String, Map<String, OrSet>> sets,
  ) {
    final bb = BytesBuilder();
    final docIds = <String>{...lww.keys, ...sets.keys}.toList()..sort();
    _u32(bb, docIds.length);
    for (final docId in docIds) {
      _str(bb, docId);

      // LWW fields (sorted by name).
      final fields = lww[docId] ?? const <String, LwwRegister>{};
      final fieldNames = fields.keys.toList()..sort();
      _u32(bb, fieldNames.length);
      for (final name in fieldNames) {
        _str(bb, name);
        _bytes(bb, fields[name]!.value);
      }

      // OR-sets (sorted by name; present elements sorted by bytes).
      final docSets = sets[docId] ?? const <String, OrSet>{};
      final setNames = docSets.keys.toList()..sort();
      _u32(bb, setNames.length);
      for (final name in setNames) {
        _str(bb, name);
        final elems = docSets[name]!.present().toList()..sort(_cmpBytes);
        _u32(bb, elems.length);
        for (final e in elems) {
          _bytes(bb, e);
        }
      }
    }
    return bb.toBytes();
  }

  static void _u32(BytesBuilder bb, int v) => bb.add(<int>[
        (v >> 24) & 0xff,
        (v >> 16) & 0xff,
        (v >> 8) & 0xff,
        v & 0xff,
      ]);

  static void _bytes(BytesBuilder bb, List<int> x) {
    _u32(bb, x.length);
    bb.add(x);
  }

  static void _str(BytesBuilder bb, String s) => _bytes(bb, utf8.encode(s));

  static int _cmpBytes(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}
