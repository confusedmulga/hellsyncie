import 'dart:typed_data';

/// A single entry in a device's append-only op log.
///
/// Identity is `(deviceId, seq)`. Only the authoring device ever mints a given
/// pair, and op files are immutable, so any two copies of the same identity
/// carry identical [payload]. Duplicates are ignored by identity.
///
/// [payload] is opaque bytes for now. The CRDT engine (LWW-register maps,
/// OR-sets, RGA lists) interprets it in a later build; until then the harness
/// treats it as inert content and asserts convergence by op-log set equality.
class Op {
  Op(this.deviceId, this.seq, this.payload);

  final String deviceId;
  final int seq;
  final Uint8List payload;

  /// Stable identity key, e.g. `d3#17`.
  String get key => '$deviceId#$seq';

  @override
  bool operator ==(Object other) =>
      other is Op && other.deviceId == deviceId && other.seq == seq;

  @override
  int get hashCode => Object.hash(deviceId, seq);

  @override
  String toString() => 'Op($key, ${payload.length} B)';
}
