import 'dart:convert';
import 'dart:typed_data';

import 'hlc.dart';

// Shared by the operation codec and the CRDT state (snapshot) codec. Not
// exported: the wire primitives are an implementation detail of each format.

/// Big-endian, length-prefixed writer.
class WireWriter {
  final BytesBuilder _b = BytesBuilder();

  void u8(int v) => _b.addByte(v & 0xff);
  void raw(List<int> x) => _b.add(x);
  void u32(int v) => _b.add(<int>[
        (v >> 24) & 0xff,
        (v >> 16) & 0xff,
        (v >> 8) & 0xff,
        v & 0xff,
      ]);
  void u64(int v) =>
      _b.add(<int>[for (var s = 56; s >= 0; s -= 8) (v >> s) & 0xff]);

  void bytes(List<int> x) {
    u32(x.length);
    _b.add(x);
  }

  void str(String s) => bytes(utf8.encode(s));

  void hlc(Hlc h) {
    u64(h.wallMillis);
    u64(h.counter);
    str(h.deviceId);
  }

  Uint8List take() => _b.toBytes();
}

/// Big-endian reader; throws [FormatException] past the end.
class WireReader {
  WireReader(this._d);

  final Uint8List _d;
  int _o = 0;

  void _need(int n) {
    if (_o + n > _d.length) throw const FormatException('truncated');
  }

  int u8() {
    _need(1);
    return _d[_o++];
  }

  int u32() {
    _need(4);
    final v =
        (_d[_o] << 24) | (_d[_o + 1] << 16) | (_d[_o + 2] << 8) | _d[_o + 3];
    _o += 4;
    return v;
  }

  int u64() {
    _need(8);
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | _d[_o + i];
    }
    _o += 8;
    return v;
  }

  Uint8List bytes() {
    final n = u32();
    _need(n);
    final r = Uint8List.fromList(_d.sublist(_o, _o + n));
    _o += n;
    return r;
  }

  String str() => utf8.decode(bytes());

  /// True once every byte has been read.
  bool get atEnd => _o == _d.length;

  Hlc hlc() {
    final wall = u64();
    final counter = u64();
    final id = str();
    return Hlc(wall, counter, id);
  }
}

/// IEEE CRC-32, bytewise (no table). Guards every file format.
int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b & 0xff;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
