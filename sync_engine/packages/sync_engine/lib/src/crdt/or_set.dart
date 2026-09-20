import 'dart:typed_data';

import '../hlc.dart';

/// Observed-remove set (add-wins). Each add tags the element with a unique HLC;
/// a remove cancels the tags it observed. An element is present iff it has at
/// least one add-tag not cancelled by a remove.
///
/// Merge is tag-set union, so it is commutative, associative, and idempotent.
/// A concurrent add whose tag no remove observed always survives — add-wins.
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
    return e != null && e.adds.difference(e.removes).isNotEmpty;
  }

  /// The bytes of every present element, in arbitrary order.
  Iterable<Uint8List> present() => _elems.values
      .where((e) => e.adds.difference(e.removes).isNotEmpty)
      .map((e) => e.element);
}

class _Elem {
  _Elem(this.element);

  final Uint8List element;
  final Set<Hlc> adds = <Hlc>{};
  final Set<Hlc> removes = <Hlc>{};
}
