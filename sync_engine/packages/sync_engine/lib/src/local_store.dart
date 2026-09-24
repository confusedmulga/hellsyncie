import 'op.dart';

/// Device-private durable storage behind a `SyncClient`: the device id and
/// every op the device holds (its own and those pulled from others).
///
/// Unlike a `Backend`, a LocalStore must be HONEST. When a returned future
/// completes, the write is durable; [loadOps] returns everything appended.
/// The op log is the only durable sync state: sequence numbers, the clock, and
/// the upload queue are all rebuilt from it on open.
///
/// If a store loses ops anyway (power loss before a rename reaches disk), the
/// client re-adopts its own files from the backend and detects a reused op
/// identity at upload readback; see `DeviceIdCollisionException`.
abstract interface class LocalStore {
  /// The id this store was opened under, or null for a fresh store.
  Future<String?> loadDeviceId();

  /// Persist the device id. Called once, when a fresh store is first opened.
  Future<void> saveDeviceId(String deviceId);

  /// Every op appended so far, in any order. May contain duplicates.
  Future<List<Op>> loadOps();

  /// Durably append [ops]. Need not be atomic across the batch: a pulled op
  /// that did not persist is downloaded again, and a failed append of a local
  /// op fails the write that authored it.
  Future<void> appendOps(List<Op> ops);
}

/// A [LocalStore] held in memory. Nothing survives the process; use it for
/// tests, or for a device that bootstraps from the backend on every start.
class MemoryStore implements LocalStore {
  String? _deviceId;
  final List<Op> _ops = <Op>[];

  @override
  Future<String?> loadDeviceId() async => _deviceId;

  @override
  Future<void> saveDeviceId(String deviceId) async => _deviceId = deviceId;

  @override
  Future<List<Op>> loadOps() async => List<Op>.of(_ops);

  @override
  Future<void> appendOps(List<Op> ops) async => _ops.addAll(ops);
}
