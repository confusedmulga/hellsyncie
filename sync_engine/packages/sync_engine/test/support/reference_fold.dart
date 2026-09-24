// FROZEN ORACLE — the CRDT fold exactly as it stood before Stage 4a
// (commit 43ba9f8), class names prefixed `Ref`. Stage 4a rewrote the engine
// as an incremental, joinable CrdtState whose canonical output must stay
// byte-identical to this. Never edit this file to make a test pass.
// ignore_for_file: prefer_const_constructors
import 'dart:convert';
import 'dart:typed_data';

import 'package:sync_engine/sync_engine.dart';

/// The CRDT merge engine.
///
/// Slice 2a: LWW-register maps. Slice 2b: OR-sets (add-wins).
///
/// [materialize] is a pure, order-independent fold over the op set. Applying
/// the same ops in any order, with duplicates, yields byte-identical output.
class RefEngine {
  const RefEngine();

  Uint8List materialize(Iterable<Op> ops) {
    final lww = <String, Map<String, RefLww>>{}; // doc -> field -> reg
    final sets =
        <String, Map<String, RefOrSet>>{}; // doc -> setField -> RefOrSet
    final lists = <String, Map<String, RefRga>>{}; // doc -> listField -> RefRga

    for (final op in ops) {
      final Operation decoded;
      try {
        decoded = OperationCodec.decode(op.payload);
      } on FormatException {
        continue; // undecodable payload: skip, same as a corrupt op file
      }
      switch (decoded) {
        case final MapPut o:
          final fields = lww.putIfAbsent(o.docId, () => <String, RefLww>{});
          final incoming = RefLww(o.value, o.hlc);
          final cur = fields[o.field];
          fields[o.field] = cur == null ? incoming : cur.merge(incoming);
        case final SetAdd o:
          _setFor(sets, o.docId, o.setField).add(o.element, o.tag);
        case final SetRemove o:
          _setFor(sets, o.docId, o.setField).remove(o.element, o.observedTags);
        case final ListInsert o:
          _listFor(lists, o.docId, o.listField).insert(o.id, o.after, o.value);
        case final ListDelete o:
          _listFor(lists, o.docId, o.listField).delete(o.elementId);
      }
    }
    return _serialize(lww, sets, lists);
  }

  static RefOrSet _setFor(
    Map<String, Map<String, RefOrSet>> sets,
    String docId,
    String setField,
  ) =>
      sets.putIfAbsent(docId, () => <String, RefOrSet>{}).putIfAbsent(
            setField,
            RefOrSet.new,
          );

  static RefRga _listFor(
    Map<String, Map<String, RefRga>> lists,
    String docId,
    String listField,
  ) =>
      lists.putIfAbsent(docId, () => <String, RefRga>{}).putIfAbsent(
            listField,
            RefRga.new,
          );

  /// Canonical, length-prefixed serialization. Length prefixes keep it
  /// unambiguous for any bytes; sorting makes it order-independent.
  Uint8List _serialize(
    Map<String, Map<String, RefLww>> lww,
    Map<String, Map<String, RefOrSet>> sets,
    Map<String, Map<String, RefRga>> lists,
  ) {
    final bb = BytesBuilder();
    final docIds = <String>{...lww.keys, ...sets.keys, ...lists.keys}.toList()
      ..sort();
    _u32(bb, docIds.length);
    for (final docId in docIds) {
      _str(bb, docId);

      // LWW fields (sorted by name).
      final fields = lww[docId] ?? const <String, RefLww>{};
      final fieldNames = fields.keys.toList()..sort();
      _u32(bb, fieldNames.length);
      for (final name in fieldNames) {
        _str(bb, name);
        _bytes(bb, fields[name]!.value);
      }

      // OR-sets (sorted by name; present elements sorted by bytes).
      final docSets = sets[docId] ?? const <String, RefOrSet>{};
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
      final docLists = lists[docId] ?? const <String, RefRga>{};
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

/// Last-write-wins register: the value stamped with the greatest [hlc] wins.
///
/// [merge] is commutative, associative, and idempotent. HLCs are globally
/// unique (deviceId breaks every tie), so there is never an exact tie to
/// arbitrate.
class RefLww {
  const RefLww(this.value, this.hlc);

  final Uint8List value;
  final Hlc hlc;

  RefLww merge(RefLww other) => other.hlc.compareTo(hlc) > 0 ? other : this;
}

/// Observed-remove set (add-wins). Each add tags the element with a unique HLC;
/// a remove cancels the tags it observed. An element is present iff it has at
/// least one add-tag not cancelled by a remove.
///
/// Merge is tag-set union, so it is commutative, associative, and idempotent.
/// A concurrent add whose tag no remove observed always survives — add-wins.
class RefOrSet {
  final Map<String, _RefElem> _elems = <String, _RefElem>{};

  /// Stable key for an element's bytes. Identical bytes → identical key.
  static String keyOf(Uint8List element) =>
      element.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void add(Uint8List element, Hlc tag) {
    (_elems[keyOf(element)] ??= _RefElem(element)).adds.add(tag);
  }

  void remove(Uint8List element, Iterable<Hlc> observedTags) {
    (_elems[keyOf(element)] ??= _RefElem(element)).removes.addAll(observedTags);
  }

  bool contains(Uint8List element) {
    final e = _elems[keyOf(element)];
    return e != null && e.adds.difference(e.removes).isNotEmpty;
  }

  /// The bytes of every present element, in arbitrary order.
  Iterable<Uint8List> present() => _elems.values
      .where((e) => e.adds.difference(e.removes).isNotEmpty)
      .map((e) => e.element);
}

class _RefElem {
  _RefElem(this.element);

  final Uint8List element;
  final Set<Hlc> adds = <Hlc>{};
  final Set<Hlc> removes = <Hlc>{};
}

/// Replicated Growable Array — an ordered-list CRDT.
///
/// Each element has a unique HLC [id] and is anchored immediately after another
/// element's id (or the head). Concurrent inserts sharing an anchor are ordered
/// by id DESCENDING, so the order is a deterministic function of the op set —
/// independent of arrival order. A deleted element is tombstoned (hidden) but
/// still anchors the elements inserted after it.
///
/// Merge is idempotent and commutative. At convergence every insert is present,
/// so every anchor chain resolves back to the head and the whole list is
/// reachable.
class RefRga {
  static const String _head = '';

  final Map<String, _RefNode> _nodes = <String, _RefNode>{}; // idKey -> node
  final Map<String, List<String>> _children =
      <String, List<String>>{}; // anchorKey -> child idKeys

  static String _key(Hlc id) => '${id.wallMillis}:${id.counter}:${id.deviceId}';

  void insert(Hlc id, Hlc? after, Uint8List value) {
    final key = _key(id);
    (_nodes[key] ??= _RefNode(id)).value = value;
    final anchor = after == null ? _head : _key(after);
    final kids = _children.putIfAbsent(anchor, () => <String>[]);
    if (!kids.contains(key)) kids.add(key);
  }

  void delete(Hlc id) {
    // A delete may arrive before its insert; create a tombstone placeholder.
    (_nodes[_key(id)] ??= _RefNode(id)).deleted = true;
  }

  /// Visible element values, in list order.
  List<Uint8List> toList() {
    final out = <Uint8List>[];
    void visit(String anchor) {
      final kids = _children[anchor];
      if (kids == null) return;
      final ordered = kids.toList()
        ..sort((a, b) => _nodes[b]!.id.compareTo(_nodes[a]!.id)); // id desc
      for (final k in ordered) {
        final node = _nodes[k]!;
        if (!node.deleted) out.add(node.value);
        visit(k); // recurse regardless: a tombstone still anchors its children
      }
    }

    visit(_head);
    return out;
  }
}

class _RefNode {
  _RefNode(this.id);

  final Hlc id;
  Uint8List value = Uint8List(0);
  bool deleted = false;
}
