import 'dart:typed_data';

import '../hlc.dart';
import '../wire.dart';

/// Observed-remove set (add-wins). Each add tags the element with a unique HLC;
/// a remove cancels the tags it observed. An element is present iff it has at
/// least one add-tag not cancelled by a remove.
///
/// Merge is tag-set union, so it is commutative, associative, and idempotent.
/// A concurrent add whose tag no remove observed always survives — add-wins.
///
/// Remove-tags are tombstones and are never dropped: a joined state or a late
/// op may still carry the add they cancel. [prune] drops only add-tags that
/// are already cancelled, which no join can bring back to life.
class OrSet {
  final Map<String, _Elem> _elems = <String, _Elem>{};

  /// Stable key for an element's bytes. Identical bytes → identical key.
  static String keyOf(Uint8List element) =>
      element.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void add(Uint8List element, Hlc tag) {
    (_elems[keyOf(element)] ??= _Elem(element)).adds.add(tag);
  }

  void remove(Uint8List element, Iterable<Hlc> observedTags) {
    (_elems[keyOf(element)] ??= _Elem(element)).removes.addAll(observedTags);
  }

  bool contains(Uint8List element) {
    final e = _elems[keyOf(element)];
    return e != null && e.live.isNotEmpty;
  }

  /// The bytes of every present element, in arbitrary order.
  Iterable<Uint8List> present() =>
      _elems.values.where((e) => e.live.isNotEmpty).map((e) => e.element);

  /// Add-tags of [element] no remove has cancelled, ascending — exactly what a
  /// remove must observe to make the element absent here.
  List<Hlc> liveTags(Uint8List element) =>
      (_elems[keyOf(element)]?.live.toList() ?? <Hlc>[])..sort();

  /// Union in everything [other] knows. [other] is not modified.
  void join(OrSet other) {
    other._elems.forEach((key, o) {
      (_elems[key] ??= _Elem(o.element))
        ..adds.addAll(o.adds)
        ..removes.addAll(o.removes);
    });
  }

  /// Drop add-tags that a remove already cancelled. Join-safe: the remove-tag
  /// stays, so a joined copy of the add is cancelled again.
  void prune() {
    for (final e in _elems.values) {
      e.adds.removeAll(e.removes);
    }
  }

  /// Every tag held, added or removed.
  Iterable<Hlc> get stamps sync* {
    for (final e in _elems.values) {
      yield* e.adds;
      yield* e.removes;
    }
  }

  /// Canonical encoding: elements by key, tags ascending, tagless elements
  /// omitted. Equal sets encode to equal bytes.
  void encode(WireWriter w) {
    final keys = _elems.keys
        .where(
            (k) => _elems[k]!.adds.isNotEmpty || _elems[k]!.removes.isNotEmpty)
        .toList()
      ..sort();
    w.u32(keys.length);
    for (final k in keys) {
      final e = _elems[k]!;
      w.bytes(e.element);
      _tags(w, e.adds);
      _tags(w, e.removes);
    }
  }

  static OrSet decode(WireReader r) {
    final s = OrSet();
    final n = r.u32();
    for (var i = 0; i < n; i++) {
      final element = r.bytes();
      final e = s._elems[keyOf(element)] ??= _Elem(element);
      e.adds.addAll(_readTags(r));
      e.removes.addAll(_readTags(r));
    }
    return s;
  }

  static void _tags(WireWriter w, Set<Hlc> tags) {
    final sorted = tags.toList()..sort();
    w.u32(sorted.length);
    sorted.forEach(w.hlc);
  }

  static List<Hlc> _readTags(WireReader r) =>
      <Hlc>[for (var n = r.u32(); n > 0; n--) r.hlc()];
}

class _Elem {
  _Elem(this.element);

  final Uint8List element;
  final Set<Hlc> adds = <Hlc>{};
  final Set<Hlc> removes = <Hlc>{};

  Set<Hlc> get live => adds.difference(removes);
}
