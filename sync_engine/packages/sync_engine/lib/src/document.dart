import 'dart:convert';
import 'dart:typed_data';

import 'crdt/rga.dart';
import 'sync_client.dart';

/// Turns a value of type [T] into the opaque bytes the engine stores, and
/// back. Typing lives here, in the API — never in the data on disk — so any
/// app can bring its own codec without a format change.
///
/// A codec must be deterministic ([encode] of equal values gives equal bytes):
/// OR-set membership and list contents compare by bytes.
abstract interface class ValueCodec<T> {
  Uint8List encode(T value);
  T decode(Uint8List bytes);

  /// UTF-8 text.
  static const ValueCodec<String> string = _StringCodec();

  /// A 64-bit two's-complement integer, 8 bytes big-endian.
  static const ValueCodec<int> int64 = _Int64Codec();

  /// JSON (null, bool, num, String, List, Map) as UTF-8 text. Equal values
  /// encode equally only if map key order is equal; prefer [string] or
  /// [int64] for set elements.
  static const ValueCodec<Object?> json = _JsonCodec();
}

/// A typed view of one document in a [SyncClient]: its LWW fields, OR-sets,
/// and RGA lists. Views are cheap and hold no state — every read hits the
/// client's live merged state, every write is an op authored by the client.
class Document {
  Document(this.client, this.id);

  final SyncClient client;
  final String id;

  DocField<T> field<T>(String name, ValueCodec<T> codec) =>
      DocField<T>._(client, id, name, codec);

  DocSet<T> set<T>(String name, ValueCodec<T> codec) =>
      DocSet<T>._(client, id, name, codec);

  DocList<T> list<T>(String name, ValueCodec<T> codec) =>
      DocList<T>._(client, id, name, codec);

  /// Fires after each local edit or pull that changed this document.
  Stream<void> get changes =>
      client.changes.where((docs) => docs.contains(id)).map((_) {});
}

/// A last-writer-wins field. Concurrent writes keep the later one (by HLC);
/// a write made after seeing another always wins over it.
class DocField<T> {
  DocField._(this._client, this._doc, this.name, this._codec);

  final SyncClient _client;
  final String _doc;
  final String name;
  final ValueCodec<T> _codec;

  /// The current value, or null if the field was never set.
  T? get value {
    final bytes = _client.fieldValue(_doc, name);
    return bytes == null ? null : _codec.decode(bytes);
  }

  Future<void> set(T value) => _client.put(_doc, name, _codec.encode(value));
}

/// An add-wins set: an add concurrent with a remove survives.
class DocSet<T> {
  DocSet._(this._client, this._doc, this.name, this._codec);

  final SyncClient _client;
  final String _doc;
  final String name;
  final ValueCodec<T> _codec;

  /// Present elements, in byte order of their encoding.
  List<T> get elements => <T>[
        for (final b in _client.setElements(_doc, name)) _codec.decode(b),
      ];

  bool contains(T element) =>
      _client.setContains(_doc, name, _codec.encode(element));

  Future<void> add(T element) =>
      _client.addToSet(_doc, name, _codec.encode(element));

  /// Removes the element as this device has seen it; a concurrent add that
  /// this device has not seen survives.
  Future<void> remove(T element) =>
      _client.removeFromSet(_doc, name, _codec.encode(element));
}

/// An ordered list (RGA). Indexes refer to the list as this device sees it
/// when the edit is authored; concurrent inserts on other devices interleave
/// deterministically, identically everywhere.
class DocList<T> {
  DocList._(this._client, this._doc, this.name, this._codec);

  final SyncClient _client;
  final String _doc;
  final String name;
  final ValueCodec<T> _codec;

  /// Visible elements with their stable ids — use the ids as UI keys: they
  /// survive concurrent edits, indexes do not.
  List<ListEntry> get entries => _client.listEntries(_doc, name);

  List<T> get values => <T>[for (final e in entries) _codec.decode(e.value)];

  int get length => entries.length;

  T operator [](int index) => _codec.decode(entries[index].value);

  Future<void> insert(int index, T value) =>
      _client.insertIntoListAt(_doc, name, index, _codec.encode(value));

  Future<void> add(T value) =>
      _client.appendToList(_doc, name, _codec.encode(value));

  Future<void> removeAt(int index) =>
      _client.removeFromListAt(_doc, name, index);
}

class _StringCodec implements ValueCodec<String> {
  const _StringCodec();

  @override
  Uint8List encode(String value) => utf8.encode(value);

  @override
  String decode(Uint8List bytes) => utf8.decode(bytes);
}

class _Int64Codec implements ValueCodec<int> {
  const _Int64Codec();

  @override
  Uint8List encode(int value) => Uint8List.fromList(
      <int>[for (var s = 56; s >= 0; s -= 8) (value >> s) & 0xff]);

  @override
  int decode(Uint8List bytes) {
    if (bytes.length != 8) {
      throw FormatException('int64 needs 8 bytes, got ${bytes.length}');
    }
    var v = 0;
    for (final b in bytes) {
      v = (v << 8) | b;
    }
    return v;
  }
}

class _JsonCodec implements ValueCodec<Object?> {
  const _JsonCodec();

  @override
  Uint8List encode(Object? value) => utf8.encode(jsonEncode(value));

  @override
  Object? decode(Uint8List bytes) => jsonDecode(utf8.decode(bytes));
}
