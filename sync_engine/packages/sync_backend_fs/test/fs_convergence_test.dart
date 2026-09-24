import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sync_backend_fs/sync_backend_fs.dart';
import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

/// Minimal replica: authors ops into its own op files through a real
/// [FsBackend] and pulls everyone else's. Transport only — the merge is the
/// real [CrdtEngine].
class _Replica {
  _Replica(this.id, this.backend) : clock = Hlc.zero(id);

  final String id;
  final Backend backend;
  final Map<String, Op> log = <String, Op>{};
  final Set<String> seen = <String>{};
  Hlc clock;
  int seq = 0;
  int tick = 0; // deterministic physical clock

  Future<void> author(Operation Function(Hlc stamp) build) async {
    clock = clock.send(++tick);
    final op = Op(id, seq++, OperationCodec.encode(build(clock)));
    log[op.key] = op;
    final name = OpFileFormat.fileName(id, op.seq);
    seen.add(name);
    await backend.upload(name, OpCodec.encode(op));
  }

  Future<void> pull() async {
    for (final f in await backend.list()) {
      if (seen.contains(f.name)) continue;
      final Op op;
      try {
        op = OpCodec.decode(await backend.download(f.name));
      } on FormatException {
        continue; // partial / corrupt: not seen, retried next pull
      }
      seen.add(f.name);
      log.putIfAbsent(op.key, () => op);
    }
  }

  Uint8List state() => const CrdtEngine().materialize(log.values);
}

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

Future<void> _randomOp(_Replica r, Random rng) async {
  final doc = 'doc${rng.nextInt(2)}';
  final values = r.log.values;
  switch (rng.nextInt(5)) {
    case 0:
      await r.author((h) => MapPut(
            docId: doc,
            field: 'f${rng.nextInt(3)}',
            value: _b('v${rng.nextInt(100)}'),
            hlc: h,
          ));
    case 1:
      final el = _b('t${rng.nextInt(4)}');
      await r.author(
          (h) => SetAdd(docId: doc, setField: 'tags', element: el, tag: h));
    case 2:
      final el = _b('t${rng.nextInt(4)}');
      final observed = CrdtEngine.addTagsFor(values, doc, 'tags', el);
      await r.author((_) => SetRemove(
            docId: doc,
            setField: 'tags',
            element: el,
            observedTags: observed,
          ));
    case 3:
      final ids = CrdtEngine.elementIds(values, doc, 'items');
      final after =
          ids.isEmpty || rng.nextBool() ? null : ids[rng.nextInt(ids.length)];
      final v = _b('i${rng.nextInt(100)}');
      await r.author((h) => ListInsert(
            docId: doc,
            listField: 'items',
            id: h,
            after: after,
            value: v,
          ));
    default:
      final ids = CrdtEngine.elementIds(values, doc, 'items');
      if (ids.isEmpty) return;
      final target = ids[rng.nextInt(ids.length)];
      await r.author(
          (_) => ListDelete(docId: doc, listField: 'items', elementId: target));
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
      final count = 2 + rng.nextInt(3); // 2..4 replicas
      final replicas = <_Replica>[
        for (var i = 0; i < count; i++)
          _Replica('d$i', FsBackend(shared)), // one backend instance each
      ];

      for (var step = 0; step < 60; step++) {
        final r = replicas[rng.nextInt(replicas.length)];
        if (rng.nextInt(10) < 7) {
          await _randomOp(r, rng);
        } else {
          await r.pull();
        }
      }
      for (final r in replicas) {
        await r.pull(); // final drain: the folder is authoritative and honest
      }

      final reference = replicas.first.state();
      // Guard against a vacuous pass: real ops were written and merged. (An
      // empty state is still 4 bytes — the zero doc-count header.)
      expect(replicas.first.log.length, greaterThan(20),
          reason: 'seed $seed wrote too few ops');
      expect(reference.length, greaterThan(4),
          reason: 'seed $seed materialized nothing');
      for (final r in replicas.skip(1)) {
        expect(r.state(), reference, reason: 'seed $seed: ${r.id} diverged');
        expect(r.log.keys.toSet(), replicas.first.log.keys.toSet(),
            reason: 'seed $seed: ${r.id} op set differs');
      }
    }
  });

  test('a partially delivered op file is skipped, then picked up whole',
      () async {
    final reader = _Replica('b', FsBackend(shared));
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
    await reader.pull();
    expect(reader.log, isEmpty);

    // The rest arrives.
    File(path).writeAsBytesSync(full);
    await reader.pull();
    expect(reader.log.keys, <String>['a#0']);
  });
}
