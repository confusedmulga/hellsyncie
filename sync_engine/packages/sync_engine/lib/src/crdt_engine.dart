import 'dart:convert';
import 'dart:typed_data';

import 'crdt/lww_register.dart';
import 'engine.dart';
import 'op.dart';
import 'operation.dart';
import 'operation_codec.dart';

/// The CRDT merge engine (slice 2a: LWW-register maps).
///
/// [materialize] is a pure, order-independent fold over the op set. Applying
/// the same ops in any order, with duplicates, yields byte-identical output —
/// which is exactly the convergence the fuzzer asserts.
class CrdtEngine implements SyncEngine {
  const CrdtEngine();

  @override
  Uint8List materialize(Iterable<Op> ops) {
    // docId -> field -> winning register
    final docs = <String, Map<String, LwwRegister>>{};
    for (final op in ops) {
      final Operation decoded;
      try {
        decoded = OperationCodec.decode(op.payload);
      } on FormatException {
        continue; // undecodable payload: skip, same as a corrupt op file
      }
      switch (decoded) {
        case final MapPut put:
          final fields =
              docs.putIfAbsent(put.docId, () => <String, LwwRegister>{});
          final incoming = LwwRegister(put.value, put.hlc);
          final cur = fields[put.field];
          fields[put.field] = cur == null ? incoming : cur.merge(incoming);
      }
    }
    return _serialize(docs);
  }

  /// Canonical, length-prefixed serialization. Length prefixes keep it
  /// unambiguous for any value bytes; the sort makes it order-independent.
  Uint8List _serialize(Map<String, Map<String, LwwRegister>> docs) {
    final bb = BytesBuilder();
    final docIds = docs.keys.toList()..sort();
    bb.add(_u32(docIds.length));
    for (final docId in docIds) {
      final d = utf8.encode(docId);
      bb
        ..add(_u16(d.length))
        ..add(d);
      final fields = docs[docId]!;
      final names = fields.keys.toList()..sort();
      bb.add(_u32(names.length));
      for (final name in names) {
        final f = utf8.encode(name);
        final value = fields[name]!.value;
        bb
          ..add(_u16(f.length))
          ..add(f)
          ..add(_u32(value.length))
          ..add(value);
      }
    }
    return bb.toBytes();
  }

  static List<int> _u16(int v) => <int>[(v >> 8) & 0xff, v & 0xff];

  static List<int> _u32(int v) =>
      <int>[(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
}
