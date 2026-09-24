import 'dart:typed_data';

import 'hlc.dart';
import 'operation.dart';
import 'wire.dart';

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
  static const int _typeListInsert = 4;
  static const int _typeListDelete = 5;

  static Uint8List encode(Operation op) {
    final w = WireWriter()..u8(version);
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
      case final ListInsert o:
        w
          ..u8(_typeListInsert)
          ..str(o.docId)
          ..str(o.listField)
          ..hlc(o.id);
        final after = o.after;
        if (after == null) {
          w.u8(0);
        } else {
          w
            ..u8(1)
            ..hlc(after);
        }
        w.bytes(o.value);
      case final ListDelete o:
        w
          ..u8(_typeListDelete)
          ..str(o.docId)
          ..str(o.listField)
          ..hlc(o.elementId);
    }
    return w.take();
  }

  static Operation decode(Uint8List data) {
    final r = WireReader(data);
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
      case _typeListInsert:
        final docId = r.str();
        final listField = r.str();
        final id = r.hlc();
        final after = r.u8() == 1 ? r.hlc() : null;
        final value = r.bytes();
        return ListInsert(
          docId: docId,
          listField: listField,
          id: id,
          after: after,
          value: value,
        );
      case _typeListDelete:
        final docId = r.str();
        final listField = r.str();
        final elementId = r.hlc();
        return ListDelete(
          docId: docId,
          listField: listField,
          elementId: elementId,
        );
      default:
        throw FormatException('unknown operation type $type');
    }
  }
}
