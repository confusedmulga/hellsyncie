import 'dart:typed_data';

import 'crdt_state.dart';
import 'format.dart';
import 'wire.dart';

/// A device's merged state at a cut: the payload of a `snap_<writer>_<gen>`
/// file on the backend, and of the device's own local snapshot.
///
/// [cut] maps each author to a count: the snapshot folds in every op of that
/// author with seq below it (and possibly more). Snapshots are joinable — two
/// of them merged cover the componentwise max of their cuts.
class Snapshot {
  Snapshot({
    required this.writer,
    required this.gen,
    required Map<String, int> cut,
    required this.state,
  }) : cut = Map<String, int>.unmodifiable(cut);

  final String writer;
  final int gen;
  final Map<String, int> cut;
  final CrdtState state;

  /// Layout: magic[4] version[1] writer gen[8] cut(n × (author, count[8]))
  /// state(len-prefixed CrdtState) crc32[4] over everything before it.
  Uint8List encode() {
    final authors = cut.keys.toList()..sort();
    final w = WireWriter()
      ..raw(SnapshotFormat.magic)
      ..u8(SnapshotFormat.version)
      ..str(writer)
      ..u64(gen)
      ..u32(authors.length);
    for (final a in authors) {
      w
        ..str(a)
        ..u64(cut[a]!);
    }
    w.bytes(state.encode());
    final body = w.take();
    return (WireWriter()
          ..raw(body)
          ..u32(crc32(body)))
        .take();
  }

  /// Throws [FormatException] on bad magic, a newer version (update the app),
  /// truncation, or a checksum mismatch.
  static Snapshot decode(Uint8List data) {
    if (data.length < 4 + 1 + 4) {
      throw const FormatException('snapshot truncated');
    }
    for (var i = 0; i < 4; i++) {
      if (data[i] != SnapshotFormat.magic[i]) {
        throw const FormatException('bad snapshot magic');
      }
    }
    final version = data[4];
    if (version > SnapshotFormat.version) {
      throw FormatException('unsupported snapshot version $version — update '
          'app');
    }
    final body = Uint8List.sublistView(data, 0, data.length - 4);
    final stored = WireReader(Uint8List.sublistView(data, data.length - 4));
    if (stored.u32() != crc32(body)) {
      throw const FormatException('snapshot checksum mismatch');
    }
    final r = WireReader(Uint8List.sublistView(body, 5));
    final writer = r.str();
    final gen = r.u64();
    final cut = <String, int>{
      for (var n = r.u32(); n > 0; n--) r.str(): r.u64(),
    };
    final state = CrdtState.decode(r.bytes());
    if (!r.atEnd) throw const FormatException('trailing bytes in snapshot');
    return Snapshot(writer: writer, gen: gen, cut: cut, state: state);
  }
}
