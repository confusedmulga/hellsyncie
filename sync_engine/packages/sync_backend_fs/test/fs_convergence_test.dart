import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sync_backend_fs/sync_backend_fs.dart';
import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

Future<void> _randomOp(SyncClient c, Random rng) async {
  final doc = 'doc${rng.nextInt(2)}';
  switch (rng.nextInt(5)) {
    case 0:
      await c.put(doc, 'f${rng.nextInt(3)}', _b('v${rng.nextInt(100)}'));
    case 1:
      await c.addToSet(doc, 'tags', _b('t${rng.nextInt(4)}'));
    case 2:
      await c.removeFromSet(doc, 'tags', _b('t${rng.nextInt(4)}'));
    case 3:
      final ids = c.listElementIds(doc, 'items');
      final after =
          ids.isEmpty || rng.nextBool() ? null : ids[rng.nextInt(ids.length)];
      await c.insertIntoList(doc, 'items', _b('i${rng.nextInt(100)}'),
          after: after);
    default:
      final ids = c.listElementIds(doc, 'items');
      if (ids.isEmpty) return;
      await c.removeFromList(doc, 'items', ids[rng.nextInt(ids.length)]);
  }
}

void main() {
  late Directory shared;

  setUp(() async {
    shared = await Directory.systemTemp.createTemp('hsy_fs_conv_');
  });

  tearDown(() async {
    if (await shared.exists()) await shared.delete(recursive: true);
  });

  test('replicas sharing one folder converge to byte-identical state',
      () async {
    for (var seed = 0; seed < 20; seed++) {
      // Fresh folder per seed.
      for (final e in shared.listSync()) {
        e.deleteSync(recursive: true);
      }
      final rng = Random(seed);
      var tick = 0; // deterministic physical clock
      final count = 2 + rng.nextInt(3); // 2..4 replicas
      final replicas = <SyncClient>[
        for (var i = 0; i < count; i++)
          await SyncClient.open(
            backend: FsBackend(shared), // one backend instance each
            store: MemoryStore(),
            deviceId: 'd$i',
            physicalMillis: () => tick,
          ),
      ];

      for (var step = 0; step < 60; step++) {
        tick++;
        final r = replicas[rng.nextInt(replicas.length)];
        if (rng.nextInt(10) < 7) {
          await _randomOp(r, rng);
        } else {
          await r.sync();
        }
      }
      // Final drain: the folder is authoritative and honest; two passes so the
      // last replica's push reaches the first.
      for (var pass = 0; pass < 2; pass++) {
        for (final r in replicas) {
          await r.sync();
        }
      }

      final reference = replicas.first.materialize();
      // Guard against a vacuous pass: real ops were written and merged. (An
      // empty state is still 4 bytes — the zero doc-count header.)
      expect(replicas.first.ops.length, greaterThan(20),
          reason: 'seed $seed wrote too few ops');
      expect(reference.length, greaterThan(4),
          reason: 'seed $seed materialized nothing');
      for (final r in replicas.skip(1)) {
        expect(r.materialize(), reference,
            reason: 'seed $seed: ${r.deviceId} diverged');
        expect(r.ops.map((o) => o.key).toSet(),
            replicas.first.ops.map((o) => o.key).toSet(),
            reason: 'seed $seed: ${r.deviceId} op set differs');
      }
    }
  });

  test('a partially delivered op file is skipped, then picked up whole',
      () async {
    final reader = await SyncClient.open(
        backend: FsBackend(shared), store: MemoryStore(), deviceId: 'b');
    final op = Op(
      'a',
      0,
      OperationCodec.encode(MapPut(
        docId: 'd',
        field: 'f',
        value: _b('v'),
        hlc: const Hlc(1, 0, 'a'),
      )),
    );
    final full = OpCodec.encode(op);
    final path =
        '${shared.path}${Platform.pathSeparator}${OpFileFormat.fileName('a', 0)}';

    // A desktop sync client has delivered only part of device a's file.
    File(path).writeAsBytesSync(full.sublist(0, full.length - 5));
    await reader.sync();
    expect(reader.ops, isEmpty);

    // The rest arrives.
    File(path).writeAsBytesSync(full);
    await reader.sync();
    expect(reader.ops.map((o) => o.key), <String>['a#0']);
  });
}
