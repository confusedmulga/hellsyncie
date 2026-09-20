import 'dart:typed_data';

import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

void main() {
  Uint8List v(String s) => Uint8List.fromList(s.codeUnits);
  List<String> order(Rga r) =>
      r.toList().map((b) => String.fromCharCodes(b)).toList();

  test('head inserts prepend (most recent first)', () {
    final r = Rga();
    r.insert(const Hlc(1, 0, 'a'), null, v('A'));
    r.insert(const Hlc(2, 0, 'a'), null, v('B')); // newer, after head
    expect(order(r), <String>['B', 'A']);
  });

  test('insert-after places immediately after the anchor', () {
    final r = Rga();
    final a = const Hlc(1, 0, 'a');
    r.insert(a, null, v('A'));
    r.insert(const Hlc(2, 0, 'a'), a, v('B')); // after A
    r.insert(const Hlc(3, 0, 'a'), a, v('C')); // also after A -> before B
    expect(order(r), <String>['A', 'C', 'B']);
  });

  test('delete hides an element but keeps its followers', () {
    final r = Rga();
    final a = const Hlc(1, 0, 'a');
    r.insert(a, null, v('A'));
    r.insert(const Hlc(2, 0, 'a'), a, v('B')); // after A
    r.delete(a);
    expect(order(r), <String>['B']); // A hidden, B (anchored on A) survives
  });

  test('a delete arriving before its insert still hides the element', () {
    final r = Rga();
    final id = const Hlc(5, 0, 'a');
    r.delete(id); // tombstone first
    r.insert(id, null, v('X')); // insert later
    expect(order(r), <String>[]);
  });
}
