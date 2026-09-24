import 'dart:typed_data';

import 'format.dart';
import 'wire.dart';

/// What a device announces in its `cursor_<id>.bin`: per author, how many of
/// that author's ops (seq 0 up) it holds durably, and the writer's clock when
/// it said so. Compaction deletes an op file only once every live device's
/// cursor covers it; a device whose cursor is older than the retention window
/// counts as gone and catches up from snapshots when it returns.
class Cursor {
  Cursor({
    required this.writer,
    required this.timeMillis,
    required Map<String, int> frontier,
  }) : frontier = Map<String, int>.unmodifiable(frontier);

  final String writer;
  final int timeMillis;
  final Map<String, int> frontier;

  /// Layout: magic[4] version[1] writer time[8] n × (author, count[8])
  /// crc32[4] over everything before it.
  Uint8List encode() {
    final authors = frontier.keys.toList()..sort();
    final w = WireWriter()
      ..raw(CursorFormat.magic)
      ..u8(CursorFormat.version)
      ..str(writer)
      ..u64(timeMillis)
      ..u32(authors.length);
    for (final a in authors) {
      w
        ..str(a)
        ..u64(frontier[a]!);
    }
    final body = w.take();
    return (WireWriter()
          ..raw(body)
          ..u32(crc32(body)))
        .take();
  }

  /// Throws [FormatException] on bad magic, a newer version, truncation, or a
  /// checksum mismatch.
  static Cursor decode(Uint8List data) {
    if (data.length < 4 + 1 + 4) {
      throw const FormatException('cursor truncated');
    }
    for (var i = 0; i < 4; i++) {
      if (data[i] != CursorFormat.magic[i]) {
        throw const FormatException('bad cursor magic');
      }
    }
    if (data[4] > CursorFormat.version) {
      throw FormatException('unsupported cursor version ${data[4]} — update '
          'app');
    }
    final body = Uint8List.sublistView(data, 0, data.length - 4);
    if (WireReader(Uint8List.sublistView(data, data.length - 4)).u32() !=
        crc32(body)) {
      throw const FormatException('cursor checksum mismatch');
    }
    final r = WireReader(Uint8List.sublistView(body, 5));
    final writer = r.str();
    final time = r.u64();
    final frontier = <String, int>{
      for (var n = r.u32(); n > 0; n--) r.str(): r.u64(),
    };
    if (!r.atEnd) throw const FormatException('trailing bytes in cursor');
    return Cursor(writer: writer, timeMillis: time, frontier: frontier);
  }
}
