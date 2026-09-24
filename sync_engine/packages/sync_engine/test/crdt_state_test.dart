import 'dart:math';
import 'dart:typed_data';

import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

import 'support/reference_fold.dart';

/// A random but well-formed op history: several devices, unique HLC stamps,
/// contended docs/fields/elements, removes observing random subsets of known
/// (and sometimes never-seen) tags, list inserts anchored anywhere including on
/// tombstones, deletes that may be delivered before their insert, exact
/// duplicate ops, and the odd undecodable payload.
List<Op> randomHistory(Random rng) {
  final devices = <String>['a', 'b', 'c', 'd'].sublist(0, 1 + rng.nextInt(4));
  final seq = <String, int>{for (final d in devices) d: 0};
  final ops = <Op>[];
  final tagsByElement = <String, List<Hlc>>{};
  final listIds = <String, List<Hlc>>{};
  var wall = 0;
  Uint8List bytes(String s) => Uint8List.fromList(s.codeUnits);

  final n = rng.nextInt(60);
  for (var i = 0; i < n; i++) {
    final dev = devices[rng.nextInt(devices.length)];
    // Stamps are unique per (wall, counter, device); walls repeat and skew.
    wall += rng.nextInt(3) - (rng.nextInt(10) == 0 ? 2 : 0);
    if (wall < 0) wall = 0;
    final stamp = Hlc(wall, i, dev);
    final doc = 'doc${rng.nextInt(3)}';
    final Operation operation;
    switch (rng.nextInt(6)) {
      case 0:
        operation = MapPut(
          docId: doc,
          field: 'f${rng.nextInt(4)}',
          value: bytes('v$i'),
          hlc: stamp,
        );
      case 1:
        final el = 't${rng.nextInt(5)}';
        (tagsByElement['$doc/$el'] ??= <Hlc>[]).add(stamp);
        operation = SetAdd(
            docId: doc, setField: 'tags', element: bytes(el), tag: stamp);
      case 2:
        final el = 't${rng.nextInt(5)}';
        final known = tagsByElement['$doc/$el'] ?? <Hlc>[];
        operation = SetRemove(
          docId: doc,
          setField: 'tags',
          element: bytes(el),
          observedTags: <Hlc>[
            for (final t in known)
              if (rng.nextBool()) t,
            if (rng.nextInt(8) == 0) Hlc(wall + 100, i, 'zz'), // never added
          ],
        );
      case 3:
      case 4:
        final ids = listIds[doc] ??= <Hlc>[];
        final after = ids.isEmpty || rng.nextInt(4) == 0
            ? null
            : ids[rng.nextInt(ids.length)];
        ids.add(stamp);
        operation = ListInsert(
          docId: doc,
          listField: 'items',
          id: stamp,
          after: after,
          value: bytes('i$i'),
        );
      default:
        final ids = listIds[doc] ?? <Hlc>[];
        if (ids.isEmpty) continue;
        operation = ListDelete(
          docId: doc,
          listField: 'items',
          elementId: ids[rng.nextInt(ids.length)],
        );
    }
    final s = seq[dev]!;
    seq[dev] = s + 1;
    ops.add(Op(dev, s, OperationCodec.encode(operation)));
  }
  if (rng.nextInt(10) == 0) {
    ops.add(Op('junk', 0, Uint8List.fromList(<int>[0xff, 0x01, 0x02])));
  }
  return ops;
}

/// A random delivery: shuffled, with some ops delivered twice.
List<Op> deliver(List<Op> ops, Random rng) => <Op>[
      ...ops,
      for (final op in ops)
        if (rng.nextInt(5) == 0) op,
    ]..shuffle(rng);

/// Full internal state, normalized: pruned and canonically encoded. Two states
/// with equal normal forms hold exactly the same knowledge.
Uint8List normal(CrdtState s) => (s.copy()..prune()).encode();

CrdtState joined(Iterable<CrdtState> states) {
  final out = CrdtState();
  for (final s in states) {
    out.join(s);
  }
  return out;
}

/// Random, possibly overlapping, parts that together cover [ops].
List<List<Op>> split(List<Op> ops, Random rng, int parts) {
  final out = <List<Op>>[for (var i = 0; i < parts; i++) <Op>[]];
  for (final op in ops) {
    out[rng.nextInt(parts)].add(op);
    if (rng.nextInt(4) == 0) out[rng.nextInt(parts)].add(op); // overlap
  }
  return out;
}

void main() {
  const engine = CrdtEngine();
  const reference = RefEngine();

  test('renders byte-identical to the frozen pre-4a fold (10k histories)', () {
    final rng = Random(4001);
    for (var i = 0; i < 10000; i++) {
      final ops = randomHistory(rng);
      final expected = reference.materialize(ops);
      expect(engine.materialize(deliver(ops, rng)), expected,
          reason: 'history $i');
    }
  });

  test('join of any split equals the fold of the union', () {
    final rng = Random(4002);
    for (var i = 0; i < 2000; i++) {
      final ops = randomHistory(rng);
      final whole = CrdtEngine.fold(ops);
      final parts = split(ops, rng, 2 + rng.nextInt(3));
      final states = parts.map(CrdtEngine.fold).toList();

      final j = joined(states);
      expect(normal(j), normal(whole), reason: 'history $i: join');
      expect(j.serialize(), reference.materialize(ops), reason: 'history $i');
      expect(j.maxStamp, whole.maxStamp, reason: 'history $i: maxStamp');
      // Commutative, associative: any order and grouping.
      final reversed = joined(states.reversed);
      expect(normal(reversed), normal(whole), reason: 'history $i: order');
      final grouped = joined(<CrdtState>[
        states.first,
        joined(states.skip(1)),
      ]);
      expect(normal(grouped), normal(whole), reason: 'history $i: grouping');
      // Idempotent: joining again, or with itself, changes nothing.
      final twice = joined(<CrdtState>[...states, ...states, whole]);
      expect(normal(twice), normal(whole), reason: 'history $i: idempotent');
    }
  });

  test('pruned parts still join to the fold of the union', () {
    final rng = Random(4003);
    for (var i = 0; i < 2000; i++) {
      final ops = randomHistory(rng);
      final parts = split(ops, rng, 2 + rng.nextInt(2));
      final states = <CrdtState>[
        for (final p in parts)
          CrdtEngine.fold(p)..prune(), // a snapshot is pruned before upload
      ];
      final j = joined(states);
      expect(j.serialize(), reference.materialize(ops), reason: 'history $i');
      expect(normal(j), normal(CrdtEngine.fold(ops)), reason: 'history $i');
      // And a pruned state keeps absorbing late ops correctly.
      final late = CrdtEngine.fold(parts.first)..prune();
      parts.skip(1).expand((p) => p).forEach(late.applyOp);
      expect(late.serialize(), reference.materialize(ops),
          reason: 'history $i: late ops');
    }
  });

  test('prune changes neither the rendered state nor maxStamp', () {
    final rng = Random(4004);
    for (var i = 0; i < 2000; i++) {
      final s = CrdtEngine.fold(randomHistory(rng));
      final rendered = s.serialize();
      final max = s.maxStamp;
      s.prune();
      expect(s.serialize(), rendered, reason: 'history $i');
      expect(s.maxStamp, max, reason: 'history $i');
    }
  });

  group('state codec', () {
    test('round-trips canonically', () {
      final rng = Random(4005);
      for (var i = 0; i < 2000; i++) {
        final ops = randomHistory(rng);
        final s = CrdtEngine.fold(ops);
        if (rng.nextBool()) s.prune();
        final bytes = s.encode();
        final back = CrdtState.decode(bytes);
        expect(back.encode(), bytes, reason: 'history $i');
        expect(back.serialize(), s.serialize(), reason: 'history $i');
        expect(back.maxStamp, s.maxStamp, reason: 'history $i');
        // Arrival order does not change the encoding.
        expect(CrdtEngine.fold(deliver(ops, rng)).encode(),
            CrdtEngine.fold(ops).encode(),
            reason: 'history $i: order');
      }
    });

    test('rejects a newer version, truncation, and trailing bytes', () {
      final ops = randomHistory(Random(4006));
      final bytes = CrdtEngine.fold(ops).encode();
      final newer = Uint8List.fromList(bytes)..[0] = CrdtState.stateVersion + 1;
      expect(() => CrdtState.decode(newer), throwsFormatException);
      for (var cut = 0; cut < bytes.length; cut++) {
        expect(() => CrdtState.decode(Uint8List.sublistView(bytes, 0, cut)),
            throwsFormatException,
            reason: 'cut at $cut');
      }
      expect(() => CrdtState.decode(Uint8List.fromList(<int>[...bytes, 0])),
          throwsFormatException);
    });
  });

  group('queries', () {
    test('maxStamp is the highest stamp any op carries', () {
      final rng = Random(4007);
      for (var i = 0; i < 1000; i++) {
        final ops = randomHistory(rng);
        Hlc? expected;
        for (final op in ops) {
          final Operation o;
          try {
            o = OperationCodec.decode(op.payload);
          } on FormatException {
            continue;
          }
          final stamps = switch (o) {
            MapPut(:final hlc) => <Hlc>[hlc],
            SetAdd(:final tag) => <Hlc>[tag],
            SetRemove(:final observedTags) => observedTags,
            ListInsert(:final id, :final after) => <Hlc>[
                id,
                if (after != null) after,
              ],
            ListDelete(:final elementId) => <Hlc>[elementId],
          };
          for (final s in stamps) {
            if (expected == null || s.compareTo(expected) > 0) expected = s;
          }
        }
        expect(CrdtEngine.fold(ops).maxStamp, expected, reason: 'history $i');
      }
    });

    test('addTagsFor is the live tags; elementIds every inserted id', () {
      Uint8List b(String s) => Uint8List.fromList(s.codeUnits);
      const t1 = Hlc(1, 0, 'a'), t2 = Hlc(2, 0, 'b'), t3 = Hlc(3, 0, 'a');
      final s = CrdtState()
        ..apply(SetAdd(docId: 'd', setField: 's', element: b('x'), tag: t2))
        ..apply(SetAdd(docId: 'd', setField: 's', element: b('x'), tag: t1))
        ..apply(SetRemove(
            docId: 'd', setField: 's', element: b('x'), observedTags: [t2]))
        ..apply(const ListDelete(docId: 'd', listField: 'l', elementId: t3))
        ..apply(ListInsert(
            docId: 'd', listField: 'l', id: t2, after: null, value: b('B')))
        ..apply(ListInsert(
            docId: 'd', listField: 'l', id: t1, after: t2, value: b('A')))
        ..apply(ListDelete(docId: 'd', listField: 'l', elementId: t2));
      expect(s.addTagsFor('d', 's', b('x')), <Hlc>[t1]);
      expect(s.addTagsFor('d', 's', b('never')), isEmpty);
      // t3 was only ever deleted (no insert yet): not an element.
      expect(s.elementIds('d', 'l'), <Hlc>[t1, t2]);
      expect(s.elementIds('d', 'missing'), isEmpty);
    });
  });
}
