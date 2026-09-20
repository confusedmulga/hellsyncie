import 'dart:typed_data';

import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

void main() {
  const engine = CrdtEngine();

  Op put(String dev, int seq, String doc, String field, String value,
          Hlc hlc) =>
      Op(
        dev,
        seq,
        OperationCodec.encode(
          MapPut(
            docId: doc,
            field: field,
            value: Uint8List.fromList(value.codeUnits),
            hlc: hlc,
          ),
        ),
      );

  test('materialize is order-independent and idempotent', () {
    final ops = <Op>[
      put('a', 0, 'doc', 'title', 'first', const Hlc(1, 0, 'a')),
      put('b', 0, 'doc', 'title', 'second', const Hlc(2, 0, 'b')),
      put('a', 1, 'doc', 'tag', 'x', const Hlc(3, 0, 'a')),
    ];
    final forward = engine.materialize(ops);
    expect(engine.materialize(ops.reversed), forward); // commutative
    expect(engine.materialize(<Op>[...ops, ...ops]), forward); // idempotent
  });

  test('last-writer-wins by HLC', () {
    final low = put('a', 0, 'd', 'f', 'lose', const Hlc(1, 0, 'a'));
    final high = put('b', 0, 'd', 'f', 'win', const Hlc(9, 0, 'b'));
    final s1 = engine.materialize(<Op>[low, high]);
    final s2 = engine.materialize(<Op>[high, low]);
    expect(s1, s2);
    expect(String.fromCharCodes(s1), contains('win'));
    expect(String.fromCharCodes(s1), isNot(contains('lose')));
  });

  test('an undecodable payload is skipped, not thrown', () {
    final good = put('a', 0, 'd', 'f', 'ok', const Hlc(1, 0, 'a'));
    final garbage = Op('z', 0, Uint8List.fromList(<int>[0xff, 0xff, 0xff]));
    final s = engine.materialize(<Op>[good, garbage]);
    expect(String.fromCharCodes(s), contains('ok'));
  });

  Op setAdd(String dev, int seq, String doc, String set, String e, Hlc tag) =>
      Op(
        dev,
        seq,
        OperationCodec.encode(SetAdd(
          docId: doc,
          setField: set,
          element: Uint8List.fromList(e.codeUnits),
          tag: tag,
        )),
      );

  Op setRemove(
    String dev,
    int seq,
    String doc,
    String set,
    String e,
    List<Hlc> observed,
  ) =>
      Op(
        dev,
        seq,
        OperationCodec.encode(SetRemove(
          docId: doc,
          setField: set,
          element: Uint8List.fromList(e.codeUnits),
          observedTags: observed,
        )),
      );

  test('OR-set is add-wins and converges regardless of order', () {
    final add1 = setAdd('a', 0, 'd', 'tags', 'x', const Hlc(1, 0, 'a'));
    final add2 = setAdd('b', 0, 'd', 'tags', 'x', const Hlc(2, 0, 'b'));
    // A remove that observed only the first add.
    final rem =
        setRemove('a', 1, 'd', 'tags', 'x', <Hlc>[const Hlc(1, 0, 'a')]);
    final ops = <Op>[add1, add2, rem];
    final forward = engine.materialize(ops);
    expect(engine.materialize(ops.reversed), forward); // order-independent
    expect(engine.materialize(<Op>[...ops, ...ops]), forward); // idempotent
    expect(String.fromCharCodes(forward), contains('x')); // add-wins
  });

  test('OR-set element fully removed when all its tags are observed', () {
    final add = setAdd('a', 0, 'd', 'tags', 'y', const Hlc(1, 0, 'a'));
    final rem =
        setRemove('a', 1, 'd', 'tags', 'y', <Hlc>[const Hlc(1, 0, 'a')]);
    final s = engine.materialize(<Op>[add, rem]);
    expect(String.fromCharCodes(s), isNot(contains('y')));
  });

  Op listInsert(
    String dev,
    int seq,
    String doc,
    String list,
    String value,
    Hlc id,
    Hlc? after,
  ) =>
      Op(
        dev,
        seq,
        OperationCodec.encode(ListInsert(
          docId: doc,
          listField: list,
          id: id,
          after: after,
          value: Uint8List.fromList(value.codeUnits),
        )),
      );

  test('RGA order is a deterministic function of the op set', () {
    final a = const Hlc(1, 0, 'a');
    final ops = <Op>[
      listInsert('a', 0, 'd', 'items', 'A', a, null),
      listInsert('a', 1, 'd', 'items', 'B', const Hlc(2, 0, 'a'), a),
      listInsert('b', 0, 'd', 'items', 'C', const Hlc(2, 0, 'b'), a),
    ];
    final forward = engine.materialize(ops);
    expect(engine.materialize(ops.reversed), forward); // order-independent
    expect(engine.materialize(<Op>[...ops, ...ops]), forward); // idempotent
    // Both B and C are inserted after A; the greater id (deviceId 'b') wins the
    // slot right after A. Result: A, C, B.
    final s = String.fromCharCodes(forward);
    expect(s.indexOf('A') < s.indexOf('C'), isTrue);
    expect(s.indexOf('C') < s.indexOf('B'), isTrue);
  });
}
