import 'dart:typed_data';

import '../hlc.dart';

/// Last-write-wins register: the value stamped with the greatest [hlc] wins.
///
/// [merge] is commutative, associative, and idempotent. HLCs are globally
/// unique (deviceId breaks every tie), so there is never an exact tie to
/// arbitrate.
class LwwRegister {
  const LwwRegister(this.value, this.hlc);

  final Uint8List value;
  final Hlc hlc;

  LwwRegister merge(LwwRegister other) =>
      other.hlc.compareTo(hlc) > 0 ? other : this;
}
