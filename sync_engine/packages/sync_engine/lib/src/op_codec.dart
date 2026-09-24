import 'dart:convert';
import 'dart:typed_data';

import 'format.dart';
import 'op.dart';
import 'wire.dart';

/// Encodes/decodes an [Op] to the versioned op-file byte layout.
///
/// Layout (big-endian integers):
///
///     magic[4] version[1] idLen[2] id[idLen] seq[8] payloadLen[4] payload[..] crc32[4]
///
/// [decode] throws [FormatException] on bad magic, an unsupported (higher)
/// version, truncation, or a checksum mismatch. Callers SKIP such files and
/// re-fetch later; a partially written or corrupt op is never applied.
class OpCodec {
  OpCodec._();

  static const int _minLength = 4 + 1 + 2 + 8 + 4 + 4;

  static Uint8List encode(Op op) {
    final id = utf8.encode(op.deviceId);
    final body = BytesBuilder()
      ..add(OpFileFormat.magic)
      ..addByte(OpFileFormat.version)
      ..add(_u16(id.length))
      ..add(id)
      ..add(_u64(op.seq))
      ..add(_u32(op.payload.length))
      ..add(op.payload);
    final withoutCrc = body.toBytes();
    return (BytesBuilder()
          ..add(withoutCrc)
          ..add(_u32(crc32(withoutCrc))))
        .toBytes();
  }

  static Op decode(Uint8List data) {
    if (data.length < _minLength) {
      throw const FormatException('op file truncated (shorter than header)');
    }
    for (var i = 0; i < 4; i++) {
      if (data[i] != OpFileFormat.magic[i]) {
        throw const FormatException('bad magic bytes');
      }
    }
    final version = data[4];
    if (version > OpFileFormat.version) {
      throw FormatException('unsupported format version $version — update app');
    }

    var off = 5;
    final idLen = _ru16(data, off);
    off += 2;
    if (off + idLen + 8 + 4 + 4 > data.length) {
      throw const FormatException('op file truncated (id/header)');
    }
    final id = utf8.decode(data.sublist(off, off + idLen));
    off += idLen;
    final seq = _ru64(data, off);
    off += 8;
    final payloadLen = _ru32(data, off);
    off += 4;
    if (off + payloadLen + 4 > data.length) {
      throw const FormatException('op file truncated (payload)');
    }
    final payload = Uint8List.fromList(data.sublist(off, off + payloadLen));
    off += payloadLen;

    final storedCrc = _ru32(data, off);
    final calcCrc = crc32(Uint8List.sublistView(data, 0, data.length - 4));
    if (storedCrc != calcCrc) {
      throw const FormatException('checksum mismatch (corrupt or truncated)');
    }
    return Op(id, seq, payload);
  }

  // --- integer helpers (big-endian) ---

  static List<int> _u16(int v) => <int>[(v >> 8) & 0xff, v & 0xff];

  static List<int> _u32(int v) =>
      <int>[(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

  static List<int> _u64(int v) =>
      <int>[for (var s = 56; s >= 0; s -= 8) (v >> s) & 0xff];

  static int _ru16(Uint8List d, int o) => (d[o] << 8) | d[o + 1];

  static int _ru32(Uint8List d, int o) =>
      (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];

  static int _ru64(Uint8List d, int o) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | d[o + i];
    }
    return v;
  }
}
