import 'dart:convert';
import 'dart:typed_data';

import 'hlc.dart';
import 'operation.dart';

/// Encodes/decodes an [Operation] to the bytes carried in an `Op.payload`.
///
/// Versioned independently of the op-file framing (`OpCodec`): the op file
/// frames opaque bytes; this layer gives those bytes structure. Layout
/// (big-endian):
///
///     opVersion[1] type[1] <type-specific>
///
/// MapPut body:
///     docLen[2] doc  fieldLen[2] field  valueLen[4] value
///     wall[8] counter[8] idLen[2] id
///
/// [decode] throws [FormatException] on an unknown/newer version, an unknown
/// type tag, or truncation. The engine treats an undecodable payload the same
/// as a corrupt op file: skip it.
class OperationCodec {
  OperationCodec._();

  static const int version = 1;

  static const int _typeMapPut = 1;

  static Uint8List encode(Operation op) {
    switch (op) {
      case final MapPut put:
        final doc = utf8.encode(put.docId);
        final field = utf8.encode(put.field);
        final id = utf8.encode(put.hlc.deviceId);
        final bb = BytesBuilder()
          ..addByte(version)
          ..addByte(_typeMapPut)
          ..add(_u16(doc.length))
          ..add(doc)
          ..add(_u16(field.length))
          ..add(field)
          ..add(_u32(put.value.length))
          ..add(put.value)
          ..add(_u64(put.hlc.wallMillis))
          ..add(_u64(put.hlc.counter))
          ..add(_u16(id.length))
          ..add(id);
        return bb.toBytes();
    }
  }

  static Operation decode(Uint8List data) {
    if (data.length < 2) throw const FormatException('operation truncated');
    final v = data[0];
    if (v > version) throw FormatException('unsupported operation version $v');
    final type = data[1];
    switch (type) {
      case _typeMapPut:
        return _decodeMapPut(data, 2);
      default:
        throw FormatException('unknown operation type $type');
    }
  }

  static MapPut _decodeMapPut(Uint8List d, int off) {
    String str(int len, int at) => utf8.decode(d.sublist(at, at + len));

    void need(int upto) {
      if (upto > d.length) throw const FormatException('operation truncated');
    }

    need(off + 2);
    final docLen = _ru16(d, off);
    off += 2;
    need(off + docLen + 2);
    final doc = str(docLen, off);
    off += docLen;
    final fieldLen = _ru16(d, off);
    off += 2;
    need(off + fieldLen + 4);
    final field = str(fieldLen, off);
    off += fieldLen;
    final valueLen = _ru32(d, off);
    off += 4;
    need(off + valueLen + 8 + 8 + 2);
    final value = Uint8List.fromList(d.sublist(off, off + valueLen));
    off += valueLen;
    final wall = _ru64(d, off);
    off += 8;
    final counter = _ru64(d, off);
    off += 8;
    final idLen = _ru16(d, off);
    off += 2;
    need(off + idLen);
    final id = str(idLen, off);
    return MapPut(
      docId: doc,
      field: field,
      value: value,
      hlc: Hlc(wall, counter, id),
    );
  }

  // --- big-endian helpers ---
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
