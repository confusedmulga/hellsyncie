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
    if (!name.startsWith('ops_') || !name.endsWith('.bin')) return null;
    final core = name.substring(4, name.length - 4);
    final i = core.lastIndexOf('_');
    if (i <= 0) return null;
    final deviceId = core.substring(0, i);
    final seq = int.tryParse(core.substring(i + 1));
    if (seq == null || seq < 0 || !isValidDeviceId(deviceId)) return null;
    // Round-trip check rejects non-canonical spellings like 'ops_a_007.bin'.
    if (fileName(deviceId, seq) != name) return null;
    return (deviceId: deviceId, seq: seq);
  }
}
