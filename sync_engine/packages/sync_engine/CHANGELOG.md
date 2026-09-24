# Changelog

## Unreleased

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
