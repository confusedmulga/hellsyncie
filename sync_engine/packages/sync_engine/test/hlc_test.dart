import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

void main() {
  test('send advances wall when physical is ahead', () {
    final c = const Hlc.zero('d0').send(100);
    expect(c.wallMillis, 100);
    expect(c.counter, 0);
  });

  test('send bumps counter when physical is not ahead', () {
    var c = const Hlc.zero('d0').send(100); // (100, 0)
    c = c.send(100); // equal -> (100, 1)
    expect(c.wallMillis, 100);
    expect(c.counter, 1);
    c = c.send(50); // behind -> (100, 2)
    expect(c.counter, 2);
  });

  test('repeated send is strictly increasing under a jittery clock', () {
    var c = const Hlc.zero('d0');
    var prev = c;
    for (var i = 0; i < 100; i++) {
      c = c.send(i % 7);
      expect(c.compareTo(prev) > 0, isTrue);
      prev = c;
    }
  });

  test('total order is wall, then counter, then deviceId', () {
    expect(const Hlc(1, 0, 'a').compareTo(const Hlc(2, 0, 'a')) < 0, isTrue);
    expect(const Hlc(2, 0, 'a').compareTo(const Hlc(2, 1, 'a')) < 0, isTrue);
    expect(const Hlc(2, 1, 'a').compareTo(const Hlc(2, 1, 'b')) < 0, isTrue);
    expect(const Hlc(2, 1, 'b') == const Hlc(2, 1, 'b'), isTrue);
  });

  test('receive takes the max wall and bumps the counter', () {
    final r = const Hlc(5, 3, 'a').receive(const Hlc(5, 9, 'b'), 2);
    expect(r.wallMillis, 5);
    expect(r.counter, 10); // max(3, 9) + 1
    expect(r.deviceId, 'a');
  });

  test('receive resets the counter when physical is ahead', () {
    final r = const Hlc(5, 3, 'a').receive(const Hlc(4, 1, 'b'), 9);
    expect(r.wallMillis, 9);
    expect(r.counter, 0);
  });
}
