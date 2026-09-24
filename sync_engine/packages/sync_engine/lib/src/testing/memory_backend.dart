import 'dart:typed_data';

import '../backend.dart';

/// An honest in-memory [Backend]: complete, current listings; uploads persist
/// exactly. Wrap it in a `FaultyBackend` to make it lie.
class MemoryBackend implements Backend {
  final Map<String, Uint8List> _files = <String, Uint8List>{};

  int get fileCount => _files.length;

  @override
  Future<List<RemoteFile>> list() async => <RemoteFile>[
        for (final MapEntry(key: name, value: bytes) in _files.entries)
          RemoteFile(name, bytes.length),
      ]..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<Uint8List> download(String name) async {
    final bytes = _files[name];
    if (bytes == null) throw StateError('download: no such file: $name');
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> upload(String name, Uint8List bytes) async =>
      _files[name] = Uint8List.fromList(bytes);

  @override
  Future<void> delete(String name) async => _files.remove(name);
}
