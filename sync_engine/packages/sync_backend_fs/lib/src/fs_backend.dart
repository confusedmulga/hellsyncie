import 'dart:io';
import 'dart:typed_data';

import 'package:sync_engine/sync_engine.dart';

/// A [Backend] over one flat directory — local disk, or a folder kept in sync
/// by a desktop client (Dropbox, Google Drive, iCloud Drive, Syncthing).
///
/// Uploads are atomic from this writer's side: bytes go to a hidden temp file,
/// are flushed to disk, then renamed onto the final name. A reader never sees
/// a half-written file from this writer. A third-party sync client may still
/// deliver partial, late, or duplicate files; the engine already tolerates all
/// of those (checksummed op files, idempotent merge, no trust in [list]).
///
/// Names beginning with '.' are reserved for temp files and hidden from [list].
/// A crash mid-upload can leave an orphaned temp file; it is invisible to every
/// device and safe to delete by hand.
///
/// Names are validated as flat, portable file names: no path separators, no
/// characters Windows forbids, no leading dot, no trailing dot or space. This
/// blocks path traversal and keeps a folder syncable across operating systems.
class FsBackend implements Backend {
  FsBackend(this.root);

  /// The folder holding the op files. Created on first upload.
  final Directory root;

  static int _tmpCounter = 0;
  static final RegExp _forbidden = RegExp(r'[/\\:*?"<>|\x00-\x1f]');

  @override
  Future<List<RemoteFile>> list() async {
    if (!await root.exists()) return const <RemoteFile>[];
    final out = <RemoteFile>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (name.startsWith('.')) continue; // temp or hidden
      try {
        out.add(RemoteFile(name, await entity.length()));
      } on FileSystemException {
        // Vanished between listing and stat (e.g. a concurrent delete).
      }
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// Throws a [FileSystemException] if [name] is not present.
  @override
  Future<Uint8List> download(String name) {
    _checkName(name);
    return _file(name).readAsBytes();
  }

  @override
  Future<void> upload(String name, Uint8List bytes) async {
    _checkName(name);
    await root.create(recursive: true);
    final tmp = File(_join('.$name.$pid-${_tmpCounter++}.tmp'));
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(_file(name).path);
    } on Object {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // Best-effort cleanup; the orphan is hidden from list() regardless.
      }
      rethrow;
    }
  }

  /// Idempotent: deleting a missing file is a no-op.
  @override
  Future<void> delete(String name) async {
    _checkName(name);
    try {
      await _file(name).delete();
    } on PathNotFoundException {
      // Already gone.
    }
  }

  File _file(String name) => File(_join(name));

  String _join(String name) => '${root.path}${Platform.pathSeparator}$name';

  static void _checkName(String name) {
    if (name.isEmpty ||
        name.startsWith('.') ||
        name.endsWith('.') ||
        name.endsWith(' ') ||
        _forbidden.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'not a valid flat file name');
    }
  }

  static String _basename(String path) {
    final i = path.lastIndexOf(RegExp(r'[/\\]'));
    return i < 0 ? path : path.substring(i + 1);
  }
}
