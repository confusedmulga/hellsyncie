# Changelog

## Unreleased

- Snapshots: `Snapshot` / `SnapshotFormat` (`snap_<id>_<gen>.bin`),
  `SyncClient.compact()`, snapshot joins on pull (before any op download),
  `frontier`, `confirmedSnapshotGen`. `SyncClient.ops` is now the log tail.
- `LocalStore` gains `loadSnapshot` / `saveSnapshot` / `removeOps`.
- Fuzzer: compaction action; coverage-set equality; reopen-from-store check.
- `CrdtState`: the merged state, updated one op at a time, joinable with
  another state (state-based CRDT), prunable, and encodable (the future
  snapshot payload). `CrdtEngine` is now a fold into it; rendered output is
  byte-identical to before.
- `SyncClient` keeps a `CrdtState` instead of re-folding the log;
  `listElementIds` added; the `engine:` parameter of `open` is removed.
- `CrdtEngine.addTagsFor` / `SyncClient.removeFromSet` observe only live
  (uncancelled) add-tags; equivalent results, smaller remove ops.
- `SyncClient`: the device-side sync loop as a public API. It persists each op
  before publishing it, confirms uploads by readback, re-adopts own ops a store
  lost, detects a device id shared by two stores, and coalesces concurrent
  `sync()` calls.
- The HLC now absorbs every ingested stamp, so an op authored after seeing
  another orders after it under any clock skew.
- `LocalStore` interface + `MemoryStore`.
- `OpFileFormat.parseFileName` / `isValidDeviceId`.
- `package:sync_engine/testing.dart`: `FaultyBackend` (the five faults over any
  backend), `MemoryBackend`, and `runFuzz(seed, backend: ...)`. Replaces the
  test-only `SimulatedBackend` / `SimulatedDevice`.

## 0.1.0

- Scaffold + simulation harness.
- `Backend` four-method contract (production interface).
- Versioned op-file format with CRC-32; corrupt/truncated files are rejected.
- `SimulatedBackend` with five independently controllable fault modes.
- `SimulatedDevice` with durable op log, unconfirmed-upload retry, crash/restart.
- Deterministic seeded fuzz driver + CLI + 1000-iteration test.
- No CRDT engine yet — convergence asserted by op-log set equality.
