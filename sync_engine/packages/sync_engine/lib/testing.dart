/// Test support for hellsyncie: an honest in-memory backend, a decorator that
/// makes ANY [Backend] lie in the five ways the contract allows, and the
/// seeded convergence fuzzer that drives real [SyncClient]s through it.
///
/// Implementing a new [Backend]? Point [runFuzz] at it over empty storage:
///
///     final result = await runFuzz(seed, backend: MyBackend(emptyBucket));
///     expect(result.converged, isTrue, reason: result.failureReason);
///
/// Pure Dart, no dependencies beyond `sync_engine` itself.
library;

import 'sync_engine.dart';

export 'src/testing/faulty_backend.dart';
export 'src/testing/fuzz_driver.dart';
export 'src/testing/memory_backend.dart';
