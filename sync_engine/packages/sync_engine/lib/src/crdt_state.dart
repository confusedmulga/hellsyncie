import 'dart:convert';
import 'dart:typed_data';

import 'crdt/lww_register.dart';
import 'crdt/or_set.dart';
import 'crdt/rga.dart';
import 'hlc.dart';
import 'op.dart';
import 'operation.dart';
import 'operation_codec.dart';
import 'wire.dart';

/// The merged CRDT state of every document: LWW-register maps, OR-sets, and
/// RGA lists, updated one operation at a time.
///
/// It is a state-based CRDT in its own right. [join] with another state gives
/// exactly the state of the union of both op sets, in any order and any number
/// of times — which is what makes a snapshot (an [encode]d state) mergeable
/// with ops, with other snapshots, and with a device that was offline for
/// months.
///
/// [serialize] is the canonical rendered form: byte-identical on every device
/// that folded the same op set, however it got them.
class CrdtState {
  final Map<String, Map<String, LwwRegister>> _lww =
      <String, Map<String, LwwRegister>>{}; // doc -> field -> register
  final Map<String, Map<String, OrSet>> _sets =
      <String, Map<String, OrSet>>{}; // doc -> setField -> OrSet
  final Map<String, Map<String, Rga>> _lists =
      <String, Map<String, Rga>>{}; // doc -> listField -> Rga

  Hlc? _maxStamp;

  /// The highest HLC this state holds, authored or referenced; null if empty.
  /// A clock set at or above it orders after every op folded in.
  Hlc? get maxStamp => _maxStamp;

  /// Fold one op in. An undecodable payload is skipped, like a corrupt file.
  void applyOp(Op op) {
    final Operation decoded;
    try {
      decoded = OperationCodec.decode(op.payload);
    } on FormatException {
      return;
    }
    apply(decoded);
  }

  /// Fold one operation in. Idempotent and order-independent.
  void apply(Operation operation) {
    switch (operation) {
      case final MapPut o:
        final fields = _lww.putIfAbsent(o.docId, () => <String, LwwRegister>{});
        final incoming = LwwRegister(o.value, o.hlc);
        final cur = fields[o.field];
        fields[o.field] = cur == null ? incoming : cur.merge(incoming);
        _see(o.hlc);
      case final SetAdd o:
        _set(o.docId, o.setField).add(o.element, o.tag);
        _see(o.tag);
      case final SetRemove o:
        _set(o.docId, o.setField).remove(o.element, o.observedTags);
        o.observedTags.forEach(_see);
      case final ListInsert o:
        _list(o.docId, o.listField).insert(o.id, o.after, o.value);
        _see(o.id);
        if (o.after != null) _see(o.after!);
      case final ListDelete o:
        _list(o.docId, o.listField).delete(o.elementId);
        _see(o.elementId);
    }
  }

  /// Merge everything [other] holds into this state. [other] is not modified.
  void join(CrdtState other) {
    other._lww.forEach((doc, fields) {
      final mine = _lww.putIfAbsent(doc, () => <String, LwwRegister>{});
      fields.forEach((field, reg) {
        final cur = mine[field];
        mine[field] = cur == null ? reg : cur.merge(reg);
      });
    });
    other._sets.forEach((doc, sets) {
      sets.forEach((name, s) => _set(doc, name).join(s));
    });
    other._lists.forEach((doc, lists) {
      lists.forEach((name, l) => _list(doc, name).join(l));
    });
    final theirs = other._maxStamp;
    if (theirs != null) _see(theirs);
  }

  /// Drop what no future op or join can make visible again (cancelled
  /// OR-set add-tags). Tombstones stay. [serialize] and [maxStamp] are
  /// unchanged.
  void prune() {
    for (final sets in _sets.values) {
      for (final s in sets.values) {
        s.prune();
      }
    }
  }

  // --- queries ---

  /// Add-tags of [element] in the OR-set that no remove has cancelled: what a
  /// remove must observe to make [element] absent. Ascending.
  List<Hlc> addTagsFor(String docId, String setField, Uint8List element) =>
      _sets[docId]?[setField]?.liveTags(element) ?? <Hlc>[];

  /// Ids of every element ever inserted into the list, deleted ones included,
  /// ascending.
  List<Hlc> elementIds(String docId, String listField) =>
      _lists[docId]?[listField]?.ids() ?? <Hlc>[];

  // --- canonical rendered form ---

  /// Canonical, length-prefixed serialization. Length prefixes keep it
  /// unambiguous for any bytes; sorting makes it order-independent.
  Uint8List serialize() {
    final bb = BytesBuilder();
    final docIds =
        <String>{..._lww.keys, ..._sets.keys, ..._lists.keys}.toList()..sort();
    _u32(bb, docIds.length);
    for (final docId in docIds) {
      _str(bb, docId);

      // LWW fields (sorted by name).
      final fields = _lww[docId] ?? const <String, LwwRegister>{};
      final fieldNames = fields.keys.toList()..sort();
      _u32(bb, fieldNames.length);
      for (final name in fieldNames) {
        _str(bb, name);
        _bytes(bb, fields[name]!.value);
      }

      // OR-sets (sorted by name; present elements sorted by bytes).
      final docSets = _sets[docId] ?? const <String, OrSet>{};
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

      // RGA lists (sorted by name; values kept in LIST ORDER, not sorted).
      final docLists = _lists[docId] ?? const <String, Rga>{};
      final listNames = docLists.keys.toList()..sort();
      _u32(bb, listNames.length);
      for (final name in listNames) {
        _str(bb, name);
        final values = docLists[name]!.toList();
        _u32(bb, values.length);
        for (final v in values) {
          _bytes(bb, v);
        }
      }
    }
    return bb.toBytes();
  }

  // --- state codec (the payload of a snapshot) ---

  /// Version of the [encode] layout.
  static const int stateVersion = 1;

  /// The full internal state, canonically: every map sorted, so equal states
  /// encode to equal bytes. Layout, all length-prefixed:
  ///
  ///     version[1]
  ///     lww:   n × (doc, n × (field, value, hlc))
  ///     sets:  n × (doc, n × (name, OrSet))
  ///     lists: n × (doc, n × (name, Rga))
  Uint8List encode() {
    final w = WireWriter()..u8(stateVersion);
    _encodeDocs(w, _lww, (reg) {
      w
        ..bytes(reg.value)
        ..hlc(reg.hlc);
    });
    _encodeDocs(w, _sets, (s) => s.encode(w));
    _encodeDocs(w, _lists, (l) => l.encode(w));
    return w.take();
  }

  /// Inverse of [encode]. Throws [FormatException] on a newer version,
  /// truncation, or trailing bytes.
  static CrdtState decode(Uint8List bytes) {
    final r = WireReader(bytes);
    final v = r.u8();
    if (v != stateVersion) {
      throw FormatException('unsupported state version $v');
    }
    final s = CrdtState();
    _decodeDocs(r, s._lww, () => LwwRegister(r.bytes(), r.hlc()));
    _decodeDocs(r, s._sets, () => OrSet.decode(r));
    _decodeDocs(r, s._lists, () => Rga.decode(r));
    if (!r.atEnd) throw const FormatException('trailing bytes after state');
    for (final fields in s._lww.values) {
      for (final reg in fields.values) {
        s._see(reg.hlc);
      }
    }
    for (final sets in s._sets.values) {
      for (final set in sets.values) {
        set.stamps.forEach(s._see);
      }
    }
    for (final lists in s._lists.values) {
      for (final list in lists.values) {
        list.stamps.forEach(s._see);
      }
    }
    return s;
  }

  /// An independent deep copy.
  CrdtState copy() => decode(encode());

  // --- internals ---

  void _see(Hlc h) {
    final m = _maxStamp;
    if (m == null || h.compareTo(m) > 0) _maxStamp = h;
  }

  OrSet _set(String docId, String setField) => _sets
      .putIfAbsent(docId, () => <String, OrSet>{})
      .putIfAbsent(setField, OrSet.new);

  Rga _list(String docId, String listField) => _lists
      .putIfAbsent(docId, () => <String, Rga>{})
      .putIfAbsent(listField, Rga.new);

  static void _encodeDocs<T>(
    WireWriter w,
    Map<String, Map<String, T>> docs,
    void Function(T) item,
  ) {
    final docIds = docs.keys.toList()..sort();
    w.u32(docIds.length);
    for (final doc in docIds) {
      final names = docs[doc]!.keys.toList()..sort();
      w
        ..str(doc)
        ..u32(names.length);
      for (final name in names) {
        w.str(name);
        item(docs[doc]![name] as T);
      }
    }
  }

  static void _decodeDocs<T>(
    WireReader r,
    Map<String, Map<String, T>> docs,
    T Function() item,
  ) {
    for (var d = r.u32(); d > 0; d--) {
      final byName = docs.putIfAbsent(r.str(), () => <String, T>{});
      for (var n = r.u32(); n > 0; n--) {
        final name = r.str();
        byName[name] = item();
      }
    }
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
