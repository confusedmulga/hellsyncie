import 'dart:typed_data';

/// One file as reported by [Backend.list].
///
/// [size] is advisory. A backend may report a size that does not match what
/// [Backend.download] later returns (e.g. a truncated upload in flight).
class RemoteFile {
  const RemoteFile(this.name, this.size);

  final String name;
  final int size;

  @override
  String toString() => 'RemoteFile($name, $size B)';
}

/// The storage contract. EXACTLY four methods. Every layer above the sync
/// engine talks to storage only through this interface. Concrete backends
/// (plain folder, S3, Google Drive appDataFolder) live in separate packages.
///
/// BACKENDS LIE. Every caller MUST assume all of the following can happen:
///
///  1. [list] may return a STALE snapshot — recently uploaded files missing.
///  2. [list] may report the SAME file more than once.
///  3. [upload] may persist only PART of the bytes and then throw.
///  4. [upload] may return normally yet persist NOTHING.
///  5. A just-uploaded file may be ABSENT from [list] for a while, then appear.
///
/// The engine tolerates all five: op files are immutable and content-addressed
/// by `(deviceId, seq)`, applying the same file twice is a no-op, and no code
/// path assumes [list] is complete. A missing file means "not visible yet";
/// sync retries later.
abstract interface class Backend {
  /// Names + advisory metadata of the files currently visible. May be stale,
  /// incomplete, or contain duplicates. Never assume it is authoritative.
  Future<List<RemoteFile>> list();

  /// Return the opaque bytes of [name]. Throws if the file is not present.
  /// Returned bytes may be corrupt or truncated; callers verify checksums.
  Future<Uint8List> download(String name);

  /// Write [bytes] under [name]. May throw after a partial write, or return
  /// normally without persisting. Callers confirm success via a later [list].
  Future<void> upload(String name, Uint8List bytes);

  /// Remove [name] if present. Idempotent.
  Future<void> delete(String name);
}
