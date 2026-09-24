/// hellsyncie sync engine — public surface.
///
/// [SyncClient] is the entry point: it authors CRDT ops into a durable
/// [LocalStore], syncs them through any [Backend], and materializes merged
/// state with [CrdtEngine]. Everything here is pure Dart with zero Flutter /
/// Drive / filesystem dependencies. Test support lives in `testing.dart`.
library;

export 'src/backend.dart';
export 'src/crdt/lww_register.dart';
export 'src/crdt/or_set.dart';
export 'src/crdt/rga.dart';
export 'src/crdt_engine.dart';
export 'src/crdt_state.dart';
export 'src/cursor.dart';
export 'src/engine.dart';
export 'src/format.dart';
export 'src/hlc.dart';
export 'src/local_store.dart';
export 'src/op.dart';
export 'src/op_codec.dart';
export 'src/operation.dart';
export 'src/operation_codec.dart';
export 'src/snapshot.dart';
export 'src/sync_client.dart';
