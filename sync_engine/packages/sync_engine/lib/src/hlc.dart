import 'dart:math';

/// Hybrid logical clock. A causality-consistent timestamp that does not trust
/// wall clocks across devices.
///
/// Total order is `(wallMillis, counter, deviceId)`. Because [deviceId] breaks
/// every tie and [counter] strictly increases within a device, any two op
/// timestamps are distinct — which is what makes LWW merge converge.
class Hlc implements Comparable<Hlc> {
  const Hlc(this.wallMillis, this.counter, this.deviceId);

  /// Zero timestamp for a device that has never ticked.
  const Hlc.zero(String deviceId) : this(0, 0, deviceId);

  final int wallMillis;
  final int counter;
  final String deviceId;

  /// Advance for a LOCAL event (authoring an op), given the current physical
  /// clock reading [physicalNow] in milliseconds.
  Hlc send(int physicalNow) {
    if (physicalNow > wallMillis) return Hlc(physicalNow, 0, deviceId);
    return Hlc(wallMillis, counter + 1, deviceId);
  }

  /// Advance on RECEIVING [remote], keeping this device's id. Not needed for LWW
  /// convergence (the winner is the global max over the op set), but kept for
  /// causal hygiene and used from later slices.
  Hlc receive(Hlc remote, int physicalNow) {
    final maxWall = max(max(wallMillis, remote.wallMillis), physicalNow);
    final int c;
    if (maxWall == wallMillis && maxWall == remote.wallMillis) {
      c = max(counter, remote.counter) + 1;
    } else if (maxWall == wallMillis) {
      c = counter + 1;
    } else if (maxWall == remote.wallMillis) {
      c = remote.counter + 1;
    } else {
      c = 0;
    }
    return Hlc(maxWall, c, deviceId);
  }

  @override
  int compareTo(Hlc other) {
    if (wallMillis != other.wallMillis) {
      return wallMillis.compareTo(other.wallMillis);
    }
    if (counter != other.counter) return counter.compareTo(other.counter);
    return deviceId.compareTo(other.deviceId);
  }

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.wallMillis == wallMillis &&
      other.counter == counter &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(wallMillis, counter, deviceId);

  @override
  String toString() => 'Hlc($wallMillis, $counter, $deviceId)';
}
