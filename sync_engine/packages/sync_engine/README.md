# sync_engine

Pure-Dart core of hellsyncie. Defines the storage `Backend` contract, the
versioned on-disk op format, and the deterministic simulation harness the CRDT
engine is built against. Zero Flutter / Drive / IO-heavy dependencies.

See the [repository README](../../../README.md) for the full picture.

Run the fuzzer from this directory:

    dart run test/harness/fuzz.dart --seed=1
    dart test
