import 'dart:typed_data';

import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

void main() {
  LwwRegister reg(int wall, String dev, String v) =>
      LwwRegister(Uint8List.fromList(v.codeUnits), Hlc(wall, 0, dev));

  test('the greater HLC wins, regardless of merge order', () {
    final a = reg(1, 'a', 'old');
    final b = reg(2, 'b', 'new');
    expect(a.merge(b).value, b.value);
    expect(b.merge(a).value, b.value);
  });

  test('deviceId breaks an equal-wall tie; merge is commutative', () {
    final a = reg(5, 'a', 'A');
    final b = reg(5, 'b', 'B'); // 'b' > 'a' -> b wins
    expect(a.merge(b).hlc, b.hlc);
    expect(b.merge(a).hlc, b.hlc);
  });

  test('merge is idempotent', () {
    final a = reg(5, 'a', 'A');
    expect(a.merge(a).hlc, a.hlc);
    expect(a.merge(a).value, a.value);
  });
}
