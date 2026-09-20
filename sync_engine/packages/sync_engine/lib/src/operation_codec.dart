import 'dart:convert';
import 'dart:typed_data';

import 'hlc.dart';
import 'operation.dart';

/// Encodes/decodes an [Operation] to the bytes carried in an `Op.payload`.
///
/// Versioned independently of the op-file framing (`OpCodec`): the op file
/// frames opaque bytes; this layer gives them structure. Every variable field
/// is length-prefixed, so any bytes are unambiguous. Layout:
///
///     opVersion[1] type[1] <type-specific, all fields length-prefixed>
///
/// [decode] throws [FormatException] on an unknown/newer version, an unknown
/// type tag, or truncation. The engine treats an undecodable payload the same
/// as a corrupt op file: skip it.
class OperationCodec {
  OperationCodec._();

  static const int version = 1;

  static const int _typeMapPut = 1;
  static const int _typeSetAdd = 2;
  static const int _typeSetRemove = 3;

  static Uint8List encode(Operation op) {
    final w = _Writer()..u8(version);
    switch (op) {
      case final MapPut o:
        w
          ..u8(_typeMapPut)
          ..str(o.docId)
          ..str(o.field)
          ..bytes(o.value)
          ..hlc(o.hlc);
      case final SetAdd o:
        w
          ..u8(_typeSetAdd)
          ..str(o.docId)
          ..str(o.setField)
          ..bytes(o.element)
          ..hlc(o.tag);
      case final SetRemove o:
        w
          ..u8(_typeSetRemove)
          ..str(o.docId)
          ..str(o.setField)
          ..bytes(o.element)
          ..u32(o.observedTags.length);
        for (final t in o.observedTags) {
          w.hlc(t);
        }
    }
    return w.take();
  }

  static Operation decode(Uint8List data) {
    final r = _Reader(data);
    final v = r.u8();
    if (v > version) throw FormatException('unsupported operation version $v');
    final type = r.u8();
    switch (type) {
      case _typeMapPut:
        final docId = r.str();
        final field = r.str();
        final value = r.bytes();
        final hlc = r.hlc();
        return MapPut(docId: docId, field: field, value: value, hlc: hlc);
      case _typeSetAdd:
        final docId = r.str();
        final setField = r.str();
        final element = r.bytes();
        final tag = r.hlc();
        return SetAdd(
          docId: docId,
          setField: setField,
          element: element,
          tag: tag,
        );
      case _typeSetRemove:
        final docId = r.str();
        final setField = r.str();
        final element = r.bytes();
        final n = r.u32();
        final tags = <Hlc>[for (var i = 0; i < n; i++) r.hlc()];
        return SetRemove(
          docId: docId,
          setField: setField,
          element: element,
          observedTags: tags,
        );
      default:
        throw FormatException('unknown operation type $type');
    }
  }
}

/// Big-endian, length-prefixed writer.
class _Writer {
  final BytesBuilder _b = BytesBuilder();

  void u8(int v) => _b.addByte(v & 0xff);
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
class _Reader {
  _Reader(this._d);

  final Uint8List _d;
  int _o = 0;

  void _need(int n) {
    if (_o + n > _d.length) throw const FormatException('operation truncated');
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

  Hlc hlc() {
    final wall = u64();
    final counter = u64();
    final id = str();
    return Hlc(wall, counter, id);
  }
}
