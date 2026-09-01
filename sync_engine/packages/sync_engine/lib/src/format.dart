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

  /// Op-file name for `(deviceId, seq)`. Each device writes ONLY files whose
  /// name carries its own id; no file is ever written by two devices.
  static String fileName(String deviceId, int seq) =>
      'ops_${deviceId}_$seq.bin';
}
