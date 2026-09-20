import 'dart:typed_data';

import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

void main() {
  Uint8List el(String s) => Uint8List.fromList(s.codeUnits);
  Set<String> present(OrSet s) =>
      s.present().map((b) => String.fromCharCodes(b)).toSet();

  test('add makes an element present; an observed remove makes it absent', () {
    final s = OrSet();
    final tag = const Hlc(1, 0, 'a');
    s.add(el('x'), tag);
    expect(present(s), contains('x'));
    s.remove(el('x'), <Hlc>[tag]);
    expect(present(s), isNot(contains('x')));
  });

  test('add-wins: a concurrent add the remove did not observe survives', () {
    final s = OrSet();
    s.add(el('x'), const Hlc(1, 0, 'a'));
    s.add(el('x'), const Hlc(2, 0, 'b'));
    s.remove(el('x'), <Hlc>[const Hlc(1, 0, 'a')]); // observed only the first
    expect(present(s), contains('x'));
  });

  test('re-add after remove brings the element back', () {
    final s = OrSet();
    final t1 = const Hlc(1, 0, 'a');
    s.add(el('x'), t1);
    s.remove(el('x'), <Hlc>[t1]);
    expect(present(s), isNot(contains('x')));
    s.add(el('x'), const Hlc(3, 0, 'a')); // fresh tag
    expect(present(s), contains('x'));
  });
}
