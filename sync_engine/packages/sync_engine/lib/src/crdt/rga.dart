import 'dart:typed_data';

import '../hlc.dart';

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
class Rga {
  static const String _head = '';

  final Map<String, _Node> _nodes = <String, _Node>{}; // idKey -> node
  final Map<String, List<String>> _children =
      <String, List<String>>{}; // anchorKey -> child idKeys

  static String _key(Hlc id) => '${id.wallMillis}:${id.counter}:${id.deviceId}';

  void insert(Hlc id, Hlc? after, Uint8List value) {
    final key = _key(id);
    (_nodes[key] ??= _Node(id)).value = value;
    final anchor = after == null ? _head : _key(after);
    final kids = _children.putIfAbsent(anchor, () => <String>[]);
    if (!kids.contains(key)) kids.add(key);
  }

  void delete(Hlc id) {
    // A delete may arrive before its insert; create a tombstone placeholder.
    (_nodes[_key(id)] ??= _Node(id)).deleted = true;
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

class _Node {
  _Node(this.id);

  final Hlc id;
  Uint8List value = Uint8List(0);
  bool deleted = false;
}
