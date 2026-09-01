/// hellsyncie sync engine — public surface.
///
/// STAGE: scaffold + simulation harness. No CRDT merge logic exists yet; the
/// engine slots in behind [SyncEngine] in a later build. Everything here is
/// pure Dart with zero Flutter / Drive / filesystem dependencies.
library;

export 'src/backend.dart';
export 'src/engine.dart';
export 'src/format.dart';
export 'src/op.dart';
export 'src/op_codec.dart';
