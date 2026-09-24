import 'dart:convert';
import 'dart:io';

import 'package:sync_engine/sync_engine.dart';

import 'fs_backend.dart';

/// A durable [LocalStore] in one directory on local disk: the device id in
/// `device_id`, and one op file per op under `ops/` — the same checksummed
/// op-file format the backend carries, written with [FsBackend]'s atomic
/// temp-file-then-rename.
///
/// Give each install its own directory (on Flutter, under the app's documents
/// directory) and never copy it to another device: the device id inside must
/// stay unique to it.
///
/// Durability limit: the rename is not followed by a directory fsync, so power
/// loss can drop the newest ops. The sync client recovers from that — it
/// re-adopts its own ops from the backend and detects a reused op identity —
/// but ops never pushed before the loss are gone.
class FsLocalStore implements LocalStore {
  FsLocalStore(this.root)
      : _meta = FsBackend(root),
        _ops = FsBackend(Directory('${root.path}${Platform.pathSeparator}ops'));

  final Directory root;
  final FsBackend _meta;
  final FsBackend _ops;

  static const String _deviceIdFile = 'device_id';

  @override
  Future<String?> loadDeviceId() async {
    try {
      return utf8.decode(await _meta.download(_deviceIdFile)).trim();
    } on PathNotFoundException {
      return null;
    }
  }

  @override
  Future<void> saveDeviceId(String deviceId) =>
      _meta.upload(_deviceIdFile, utf8.encode(deviceId));

  /// Ops in file-name order. A corrupt file is skipped: a pulled op comes back
  /// with the next sync, an own op already pushed is re-adopted.
  @override
  Future<List<Op>> loadOps() async {
    final ops = <Op>[];
    for (final f in await _ops.list()) {
      final id = OpFileFormat.parseFileName(f.name);
      if (id == null) continue;
      final Op op;
      try {
        op = OpCodec.decode(await _ops.download(f.name));
      } on FormatException {
        continue;
      }
      if (op.deviceId == id.deviceId && op.seq == id.seq) ops.add(op);
    }
    return ops;
  }

  @override
  Future<void> appendOps(List<Op> ops) async {
    for (final op in ops) {
      await _ops.upload(
          OpFileFormat.fileName(op.deviceId, op.seq), OpCodec.encode(op));
    }
  }
}
