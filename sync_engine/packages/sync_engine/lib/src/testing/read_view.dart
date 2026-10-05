import 'dart:convert';
import 'dart:typed_data';

import '../state_reader.dart';

/// Rebuild the canonical rendered state (`CrdtState.serialize()`'s layout)
/// using ONLY the public read API of [reader].
///
/// An independent oracle: if it matches `materialize()` byte for byte, the
/// read API exposes exactly the merged state — every document, field, set
/// element, and list item, in the right order — and nothing else.
Uint8List serializeFromReads(StateReader reader) {
  final out = BytesBuilder();
  void u32(int v) => out.add(
      <int>[(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
  void bytes(List<int> b) {
    u32(b.length);
    out.add(b);
  }

  void str(String s) => bytes(utf8.encode(s));

  final docs = reader.docIds;
  u32(docs.length);
  for (final doc in docs) {
    str(doc);
    final fields = reader.fieldNames(doc);
    u32(fields.length);
    for (final f in fields) {
      str(f);
      bytes(reader.fieldValue(doc, f)!);
    }
    final sets = reader.setNames(doc);
    u32(sets.length);
    for (final s in sets) {
      str(s);
      final elements = reader.setElements(doc, s);
      u32(elements.length);
      elements.forEach(bytes);
    }
    final lists = reader.listNames(doc);
    u32(lists.length);
    for (final l in lists) {
      str(l);
      final entries = reader.listEntries(doc, l);
      u32(entries.length);
      for (final e in entries) {
        bytes(e.value);
      }
    }
  }
  return out.toBytes();
}
