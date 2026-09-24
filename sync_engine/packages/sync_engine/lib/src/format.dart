/// On-disk op-file format. Versioned from day one.
///
/// Every op file begins with [magic] and a single [version] byte. Reading a
/// version higher than [version] is refused (never guessed) — the caller must
/// update. Breaking the wire layout bumps [version]; 0.x may break freely,
/// 1.0+ ships migration code.
class OpFileFormat {
  OpFileFormat._();

  /// Magic bytes 'HSY1' identifying a hellsyncie op file.
  static const List<int> magic = <int>[0x48, 0x53, 0x59, 0x31];

  /// Current on-disk format version.
  static const int version = 1;

  static final RegExp _deviceId = RegExp(r'^[A-Za-z0-9-]{1,64}$');

  /// Whether [deviceId] is usable in op-file names: 1–64 ASCII letters, digits,
  /// or '-'. Keeps names flat, portable, and unambiguous to parse.
  static bool isValidDeviceId(String deviceId) => _deviceId.hasMatch(deviceId);

  /// Op-file name for `(deviceId, seq)`. Each device writes ONLY files whose
  /// name carries its own id; no file is ever written by two devices.
  static String fileName(String deviceId, int seq) =>
      'ops_${deviceId}_$seq.bin';

  /// Inverse of [fileName]: the identity an op-file name claims, or null if
  /// [name] is not a canonical op-file name (snapshots, cursors, temp files,
  /// junk). The claim is unverified until the decoded op's key matches it.
  static ({String deviceId, int seq})? parseFileName(String name) {
    final p = _parse(name, 'ops_', fileName);
    return p == null ? null : (deviceId: p.id, seq: p.n);
  }
}

/// Snapshot files: `snap_<deviceId>_<gen>.bin`, a device's merged state at a
/// cut. Each device writes only its own; its gens only grow, and each gen's
/// state contains everything the previous gen held.
class SnapshotFormat {
  SnapshotFormat._();

  /// Magic bytes 'HSS1' identifying a hellsyncie snapshot file.
  static const List<int> magic = <int>[0x48, 0x53, 0x53, 0x31];

  /// Current snapshot format version.
  static const int version = 1;

  static String fileName(String writer, int gen) => 'snap_${writer}_$gen.bin';

  /// Inverse of [fileName], or null if [name] is not a canonical snapshot
  /// name.
  static ({String writer, int gen})? parseFileName(String name) {
    final p = _parse(name, 'snap_', fileName);
    return p == null ? null : (writer: p.id, gen: p.n);
  }
}

/// Parse `<prefix><deviceId>_<n>.bin`, accepting only the canonical spelling
/// that [make] produces.
({String id, int n})? _parse(
  String name,
  String prefix,
  String Function(String, int) make,
) {
  if (!name.startsWith(prefix) || !name.endsWith('.bin')) return null;
  final core = name.substring(prefix.length, name.length - 4);
  final i = core.lastIndexOf('_');
  if (i <= 0) return null;
  final id = core.substring(0, i);
  final n = int.tryParse(core.substring(i + 1));
  if (n == null || n < 0 || !OpFileFormat.isValidDeviceId(id)) return null;
  // Round-trip check rejects non-canonical spellings like 'ops_a_007.bin'.
  if (make(id, n) != name) return null;
  return (id: id, n: n);
}
