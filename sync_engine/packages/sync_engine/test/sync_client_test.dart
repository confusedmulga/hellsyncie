import 'dart:math';
import 'dart:typed_data';

import 'package:sync_engine/sync_engine.dart';
import 'package:sync_engine/testing.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

String _text(Uint8List state) => String.fromCharCodes(state);

Future<SyncClient> _open(
  Backend backend, {
  LocalStore? store,
  String? id,
  int Function()? clock,
}) =>
    SyncClient.open(
      backend: backend,
      store: store ?? MemoryStore(),
      deviceId: id,
      physicalMillis: clock ?? () => 1,
    );

/// A store whose next append can be made to fail.
class _FlakyStore extends MemoryStore {
  bool failNextAppend = false;

  @override
  Future<void> appendOps(List<Op> ops) {
    if (failNextAppend) {
      failNextAppend = false;
      throw StateError('disk full');
    }
    return super.appendOps(ops);
  }
}

/// Counts list() calls.
class _CountingBackend extends MemoryBackend {
  int lists = 0;

  @override
  Future<List<RemoteFile>> list() {
    lists++;
    return super.list();
  }
}

void main() {
  test('two clients converge through one backend', () async {
    final backend = MemoryBackend();
    final a = await _open(backend, id: 'a');
    final b = await _open(backend, id: 'b');
    await a.put('note', 'title', _b('Groceries'));
    await b.addToSet('note', 'tags', _b('home'));
    await b.insertIntoList('note', 'items', _b('Milk'));

    await a.sync();
    await b.sync();
    await a.sync();

    expect(a.materialize(), b.materialize());
    expect(_text(a.materialize()),
        allOf(contains('Groceries'), contains('home'), contains('Milk')));
    expect(a.pendingUploads, 0);
    expect(b.pendingUploads, 0);
  });

  group('device id', () {
    test('a fresh store draws a random id and keeps it', () async {
      final store = MemoryStore();
      final first = await SyncClient.open(
          backend: MemoryBackend(), store: store, random: Random(1));
      expect(first.deviceId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(await store.loadDeviceId(), first.deviceId);
      final again =
          await SyncClient.open(backend: MemoryBackend(), store: store);
      expect(again.deviceId, first.deviceId);
    });

    test('a store refuses a different explicit id', () async {
      final store = MemoryStore();
      await _open(MemoryBackend(), store: store, id: 'a');
      await expectLater(
          _open(MemoryBackend(), store: store, id: 'b'), throwsStateError);
    });

    test('ids that would break op-file names are rejected', () async {
      for (final bad in <String>['', 'a_b', 'a/b', 'a.b', 'x' * 65]) {
        await expectLater(_open(MemoryBackend(), id: bad), throwsArgumentError,
            reason: bad);
      }
    });
  });

  test('reopening continues the sequence and the clock', () async {
    final store = MemoryStore();
    final c1 = await _open(MemoryBackend(), store: store, id: 'a');
    await c1.put('d', 'f', _b('1'));
    await c1.put('d', 'f', _b('2'));
    final before = c1.clock;

    final c2 = await _open(MemoryBackend(), store: store, id: 'a');
    expect(c2.ops.map((o) => o.key), <String>['a#0', 'a#1']);
    expect(c2.pendingUploads, 2, reason: 'unconfirmed until read back');
    await c2.put('d', 'f', _b('3'));
    expect(c2.ops.last.key, 'a#2');
    expect(c2.clock.compareTo(before), greaterThan(0));
    expect(_text(c2.materialize()), contains('3'));
  });

  test('a failed local append authors nothing and burns no sequence number',
      () async {
    final backend = MemoryBackend();
    final store = _FlakyStore();
    final c = await _open(backend, store: store, id: 'a');

    store.failNextAppend = true;
    await expectLater(c.put('d', 'f', _b('lost')), throwsStateError);
    expect(c.ops, isEmpty);

    await c.put('d', 'f', _b('kept'));
    await c.sync();
    expect(c.ops.single.key, 'a#0');
    expect((await backend.list()).map((f) => f.name), <String>['ops_a_0.bin']);
  });

  test('a truncated upload is re-pushed until it reads back intact', () async {
    final inner = MemoryBackend();
    final faulty = FaultyBackend(inner, Random(1),
        faults: FaultConfig(truncatedUpload: 1));
    final c = await _open(faulty, id: 'a');
    await c.put('d', 'f', _b('value'));

    final first = await c.sync();
    expect(first.pending, 1);
    await expectLater(
        inner.download('ops_a_0.bin').then(OpCodec.decode), // a prefix only
        throwsFormatException);

    faulty.faults = FaultConfig.none();
    final second = await c.sync();
    expect(second.pending, 0);
    expect(OpCodec.decode(await inner.download('ops_a_0.bin')).key, 'a#0');
  });

  group('causality under clock skew', () {
    test('a write made after seeing a fast-clocked write supersedes it',
        () async {
      final backend = MemoryBackend();
      final fast = await _open(backend, id: 'fast', clock: () => 1000000);
      final slow = await _open(backend, id: 'slow', clock: () => 0);

      await fast.put('d', 'title', _b('old-title'));
      await fast.sync();
      await slow.sync();
      await slow.put('d', 'title', _b('new-title'));
      await slow.sync();
      await fast.sync();

      for (final c in <SyncClient>[fast, slow]) {
        expect(_text(c.materialize()),
            allOf(contains('new-title'), isNot(contains('old-title'))));
      }
    });

    test('an insert placed right after X lands before X\'s older sibling',
        () async {
      final backend = MemoryBackend();
      final fast = await _open(backend, id: 'fast', clock: () => 1000000);
      final slow = await _open(backend, id: 'slow', clock: () => 0);

      final x = await fast.insertIntoList('d', 'items', _b('<X>'));
      await fast.insertIntoList('d', 'items', _b('<S>'), after: x);
      await fast.sync();
      await slow.sync();
      await slow.insertIntoList('d', 'items', _b('<N>'), after: x);
      await slow.sync();
      await fast.sync();

      final text = _text(slow.materialize());
      expect(fast.materialize(), slow.materialize());
      expect(text.indexOf('<X>'), lessThan(text.indexOf('<N>')));
      expect(text.indexOf('<N>'), lessThan(text.indexOf('<S>')));
    });
  });

  test('own ops a store lost are re-adopted, never re-numbered', () async {
    final backend = MemoryBackend();
    final original = await _open(backend, id: 'a');
    for (var i = 0; i < 3; i++) {
      await original.put('d', 'f$i', _b('v$i'));
    }
    await original.sync();

    // The store lost its tail: a#2 is on the backend but not on disk.
    final damaged = MemoryStore();
    await damaged.saveDeviceId('a');
    await damaged.appendOps(original.ops.take(2).toList());
    final restored = await _open(backend, store: damaged, id: 'a');

    final result = await restored.sync();
    expect(result.received, 1);
    await restored.put('d', 'g', _b('next'));
    expect(restored.ops.last.key, 'a#3');
    await restored.sync();
    expect(restored.pendingUploads, 0);
    expect(OpCodec.decode(await backend.download('ops_a_2.bin')).payload,
        original.ops[2].payload);
  });

  test('a second store under the same id is stopped before it overwrites',
      () async {
    final backend = MemoryBackend();
    final first = await _open(backend, id: 'x');
    await first.put('d', 'f', _b('original'));
    await first.sync();

    final twin = await _open(backend, id: 'x'); // fresh store, same id
    await twin.put('d', 'f', _b('impostor'));
    await expectLater(twin.sync(), throwsA(isA<DeviceIdCollisionException>()));
    expect(OpCodec.decode(await backend.download('ops_x_0.bin')).payload,
        first.ops.single.payload);
  });

  test('files that are not op files, or contradict their name, are ignored',
      () async {
    final backend = MemoryBackend();
    Uint8List opFile(int seq) => OpCodec.encode(Op(
          'y',
          seq,
          OperationCodec.encode(MapPut(
            docId: 'd',
            field: 'f',
            value: _b('v$seq'),
            hlc: Hlc(seq, 0, 'y'),
          )),
        ));
    await backend.upload('readme.txt', _b('hello'));
    await backend.upload('ops_y_0.bin', opFile(1)); // claims y#0, holds y#1
    await backend.upload('ops_y_01.bin', opFile(1)); // non-canonical name
    await backend.upload('ops_y_1.bin', opFile(1));

    final c = await _open(backend, id: 'a');
    final result = await c.sync();
    expect(result.received, 1);
    expect(c.ops.single.key, 'y#1');
  });

  test('removing an element never seen authors nothing', () async {
    final c = await _open(MemoryBackend(), id: 'a');
    await c.removeFromSet('d', 'tags', _b('ghost'));
    expect(c.ops, isEmpty);
    await c.addToSet('d', 'tags', _b('real'));
    await c.removeFromSet('d', 'tags', _b('real'));
    expect(c.ops, hasLength(2));
    expect(_text(c.materialize()), isNot(contains('real')));
  });

  test('concurrent sync calls share one follow-up round', () async {
    final backend = _CountingBackend();
    final c = await _open(backend, id: 'a');
    await c.put('d', 'f', _b('v'));

    final results = await Future.wait(<Future<SyncResult>>[
      c.sync(), // first round after open: pull, push, pull
      c.sync(), // these two share one follow-up round: push, pull
      c.sync(),
    ]);
    expect(backend.lists, 3);
    expect(results.every((r) => r.pending == 0), isTrue);
    expect(c.ops, hasLength(1));
  });

  group('OpFileFormat.parseFileName', () {
    test('inverts fileName', () {
      final parsed =
          OpFileFormat.parseFileName(OpFileFormat.fileName('d-9', 42));
      expect(parsed?.deviceId, 'd-9');
      expect(parsed?.seq, 42);
    });

    test('rejects everything that is not a canonical op-file name', () {
      for (final name in <String>[
        'readme.txt',
        'ops_.bin',
        'ops__1.bin',
        'ops_a_.bin',
        'ops_a_x.bin',
        'ops_a_-1.bin',
        'ops_a_+1.bin',
        'ops_a_01.bin',
        'ops_a.b_1.bin',
        'ops_a_1.bin.tmp',
        '.ops_a_1.bin',
      ]) {
        expect(OpFileFormat.parseFileName(name), isNull, reason: name);
      }
    });
  });
}
