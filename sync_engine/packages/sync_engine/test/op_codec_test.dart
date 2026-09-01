import 'dart:typed_data';

import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

void main() {
  Op sample() => Op('d7', 42, Uint8List.fromList(<int>[1, 2, 3, 4, 5]));

  test('round-trips an op', () {
    final op = sample();
    final decoded = OpCodec.decode(OpCodec.encode(op));
    expect(decoded.deviceId, op.deviceId);
    expect(decoded.seq, op.seq);
    expect(decoded.payload, op.payload);
  });

  test('rejects truncated bytes', () {
    final bytes = OpCodec.encode(sample());
    final cut = Uint8List.sublistView(bytes, 0, bytes.length - 3);
    expect(
        () => OpCodec.decode(Uint8List.fromList(cut)), throwsFormatException);
  });

  test('rejects a checksum mismatch', () {
    final bytes = OpCodec.encode(sample());
    bytes[bytes.length - 6] ^= 0xff; // flip a payload byte, leave CRC stale
    expect(() => OpCodec.decode(bytes), throwsFormatException);
  });

  test('rejects an unsupported higher version', () {
    final bytes = OpCodec.encode(sample());
    bytes[4] = 99; // version byte
    expect(() => OpCodec.decode(bytes), throwsFormatException);
  });

  test('rejects bad magic', () {
    final bytes = OpCodec.encode(sample());
    bytes[0] ^= 0xff;
    expect(() => OpCodec.decode(bytes), throwsFormatException);
  });

  test('empty payload is legal', () {
    final op = Op('d0', 0, Uint8List(0));
    final decoded = OpCodec.decode(OpCodec.encode(op));
    expect(decoded.payload, isEmpty);
    expect(decoded.key, 'd0#0');
  });
}
