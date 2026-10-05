import 'dart:typed_data';

import 'package:sync_engine/sync_engine.dart';
import 'package:sync_engine/testing.dart';
import 'package:test/test.dart';

void main() {
  group('codecs', () {
    test('string round-trips any text, including multi-byte', () {
      for (final s in <String>['', 'Groceries', 'naïve café', '日本語', '🛒✅']) {
        expect(ValueCodec.string.decode(ValueCodec.string.encode(s)), s);
      }
    });

    test('int64 round-trips the whole range, big-endian', () {
      for (final n in <int>[
        0,
        1,
        -1,
        255,
        -256,
        1 << 40,
        -(1 << 40),
        0x7fffffffffffffff,
        -0x8000000000000000,
      ]) {
        expect(ValueCodec.int64.decode(ValueCodec.int64.encode(n)), n);
      }
      expect(ValueCodec.int64.encode(1), <int>[0, 0, 0, 0, 0, 0, 0, 1]);
      expect(
          () => ValueCodec.int64.decode(Uint8List(3)), throwsFormatException);
    });

    test('json round-trips nested values', () {
      final value = <String, Object?>{
        'n': 1,
        'xs': <Object?>[true, null, 'é', 2.5],
        'm': <String, Object?>{'k': <Object?>[]},
      };
      expect(ValueCodec.json.decode(ValueCodec.json.encode(value)), value);
    });
  });

  test('the README flow: typed edits on one device read back on another',
      () async {
    final backend = MemoryBackend();
    final phone = await SyncClient.open(
        backend: backend, store: MemoryStore(), deviceId: 'phone');
    final laptop = await SyncClient.open(
        backend: backend, store: MemoryStore(), deviceId: 'laptop');

    final note = phone.document('note:42');
    await note.field('title', ValueCodec.string).set('Groceries');
    await note.field('priority', ValueCodec.int64).set(-3);
    await note.set('tags', ValueCodec.string).add('home');
    final items = note.list('items', ValueCodec.string);
    await items.insert(0, 'Milk');
    await items.add('Eggs');
    await items.insert(1, 'Bread');
    expect(items.values, <String>['Milk', 'Bread', 'Eggs']);
    expect(items[1], 'Bread');

    final laptopChanges = laptop.document('note:42').changes.first;
    await phone.sync();
    await laptop.sync();
    await laptopChanges; // fired for the remote edits

    final same = laptop.document('note:42');
    expect(same.field('title', ValueCodec.string).value, 'Groceries');
    expect(same.field('priority', ValueCodec.int64).value, -3);
    expect(same.field('missing', ValueCodec.string).value, isNull);
    expect(same.set('tags', ValueCodec.string).elements, <String>['home']);
    final laptopItems = same.list('items', ValueCodec.string);
    expect(laptopItems.values, <String>['Milk', 'Bread', 'Eggs']);
    expect(laptopItems.length, 3);

    // Edits flow back the other way.
    await laptopItems.removeAt(0);
    await same.set('tags', ValueCodec.string).remove('home');
    await laptop.sync();
    await phone.sync();
    expect(items.values, <String>['Bread', 'Eggs']);
    expect(note.set('tags', ValueCodec.string).contains('home'), isFalse);
    expect(phone.materialize(), laptop.materialize());
    await phone.close();
    await laptop.close();
  });

  test('a document view only reports changes to its own document', () async {
    final c = await SyncClient.open(
        backend: MemoryBackend(), store: MemoryStore(), deviceId: 'a');
    final seen = <String>[];
    final sub = c.document('mine').changes.listen((_) => seen.add('mine'));
    await c.put('other', 'f', ValueCodec.string.encode('x'));
    await c.put('mine', 'f', ValueCodec.string.encode('y'));
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen, <String>['mine']);
  });
}
