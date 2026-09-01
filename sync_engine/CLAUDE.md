# Project: offline-first CRDT sync library for Dart

## Architecture (fixed, do not restructure)
- packages/sync_engine: pure Dart, ZERO Flutter/Drive deps
- Backend contract: list/download/upload/delete only
- Op log is append-only; each device writes only its own files
- On-disk format is versioned; breaking it requires bumping format version

## CRDT choices (decided)
- RGA for lists, LWW-register maps for fields, OR-set for collections
- Rich text CRDT: deferred, not in scope until 1.0

## Testing rules (hard)
- Simulation harness is built BEFORE engine features
- Every engine change runs the fuzz suite: N devices, random ops,
  random sync order, fault injection (truncated upload, stale listing,
  dropped file), convergence assertion at end
- NEVER weaken or delete a failing convergence assertion. Failing
  seed = engine bug. Fix the engine.
- Failing seeds get committed to test/regression_seeds.dart

## Workflow
- Plan mode first for anything touching merge or compaction logic
- No new dependencies without asking