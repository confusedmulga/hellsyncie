# sync_engine

Pure-Dart core of hellsyncie. `SyncClient` authors CRDT ops into a durable
`LocalStore`, syncs them through any four-method `Backend`, and materializes
the merged state. Also here: the versioned on-disk op format and the CRDT
engine. Zero Flutter / Drive / IO-heavy dependencies.

`package:sync_engine/testing.dart` exports the fault layer (`FaultyBackend`)
and the seeded convergence fuzzer (`runFuzz`). Point it at a new backend to
put that backend through the same faults the engine is gated on.

See the [repository README](../../../README.md) for the full picture.

Run the fuzzer from this directory:

    dart run test/harness/fuzz.dart --seed=1
    dart test
