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
}
