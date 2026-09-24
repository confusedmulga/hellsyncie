import 'dart:typed_data';

import '../hlc.dart';
import '../wire.dart';

/// Replicated Growable Array — an ordered-list CRDT.
///
/// Each element has a unique HLC id and is anchored immediately after another
/// element's id (or the head). Concurrent inserts sharing an anchor are ordered
/// by id DESCENDING, so the order is a deterministic function of the op set —
/// independent of arrival order. A deleted element is tombstoned (hidden) but
/// still anchors the elements inserted after it.
///
/// Merge is idempotent and commutative. At convergence every insert is present,
/// so every anchor chain resolves back to the head and the whole list is
/// reachable.
///
/// Tombstones are never dropped (a late insert may anchor on one), but a
/// deleted element's value is discarded at once: it can never be shown again.
class Rga {
  static const String _head = '';
  static final Uint8List _empty = Uint8List(0);

  final Map<String, _Node> _nodes = <String, _Node>{}; // idKey -> node
  final Map<String, Set<String>> _children =
      <String, Set<String>>{}; // anchorKey -> child idKeys

  static String _key(Hlc id) => '${id.wallMillis}:${id.counter}:${id.deviceId}';

  void insert(Hlc id, Hlc? after, Uint8List value) {
    final key = _key(id);
    final node = _nodes[key] ??= _Node(id);
    if (!node.deleted) node.value = value;
    if (node.inserted) return;
    node
      ..inserted = true
      ..after = after;
    _children
        .putIfAbsent(after == null ? _head : _key(after), () => <String>{})
        .add(key);
  }

  void delete(Hlc id) {
    // A delete may arrive before its insert; create a tombstone placeholder.
    (_nodes[_key(id)] ??= _Node(id))
      ..deleted = true
      ..value = _empty;
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

  /// Ids of every inserted element, deleted ones included, ascending.
  List<Hlc> ids() => <Hlc>[
        for (final n in _nodes.values)
          if (n.inserted) n.id
      ]..sort();

  /// Every id held: elements, tombstones, and anchors.
  Iterable<Hlc> get stamps sync* {
    for (final n in _nodes.values) {
      yield n.id;
      if (n.after != null) yield n.after!;
    }
  }

  /// Union in everything [other] knows. [other] is not modified.
  void join(Rga other) {
    for (final o in other._nodes.values) {
      if (o.deleted) delete(o.id); // first, so a stripped value never lands
      if (o.inserted) insert(o.id, o.after, o.value);
    }
  }

  static const int _fInserted = 1, _fDeleted = 2, _fAnchored = 4;

  /// Canonical encoding: nodes by id ascending. Equal lists encode equally.
  void encode(WireWriter w) {
    final nodes = _nodes.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    w.u32(nodes.length);
    for (final n in nodes) {
      w
        ..hlc(n.id)
        ..u8((n.inserted ? _fInserted : 0) |
            (n.deleted ? _fDeleted : 0) |
            (n.after != null ? _fAnchored : 0));
      if (n.after != null) w.hlc(n.after!);
      if (n.inserted && !n.deleted) w.bytes(n.value);
    }
  }

  static Rga decode(WireReader r) {
    final rga = Rga();
    for (var n = r.u32(); n > 0; n--) {
      final id = r.hlc();
      final flags = r.u8();
      if (flags & ~(_fInserted | _fDeleted | _fAnchored) != 0) {
        throw FormatException('unknown RGA node flags $flags');
      }
      final inserted = flags & _fInserted != 0;
      final deleted = flags & _fDeleted != 0;
      final after = flags & _fAnchored != 0 ? r.hlc() : null;
      if (after != null && !inserted) {
        throw const FormatException('anchored RGA node was never inserted');
      }
      final value = inserted && !deleted ? r.bytes() : _empty;
      if (deleted) rga.delete(id);
      if (inserted) rga.insert(id, after, value);
    }
    return rga;
  }
}

class _Node {
  _Node(this.id);

  final Hlc id;
  Uint8List value = Rga._empty;
  bool deleted = false;

  /// Whether this element's insert has been applied. False for a tombstone
  /// placeholder whose delete arrived first.
  bool inserted = false;

  /// The element this one was inserted after; null = the head.
  Hlc? after;
}
