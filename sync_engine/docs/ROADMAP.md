# ROADMAP — hellsyncie

Build order and gates. Read with `DESIGN.md` (decisions) and `../../CLAUDE.md`
(rules). Notes marked **GATE** must pass before a stage is called done.

---

## 0. INVARIANT (every stage, no exceptions)

0.1 The fuzz suite stays green. 1,000 seeds per change; 100,000 nightly.
0.2 A failing seed is an engine bug. Fix the engine. NEVER weaken or delete a
    convergence assertion.
0.3 Pin every failing seed in `test/regression_seeds.dart`. Permanent.
0.4 Plan mode before ANY change to merge or compaction logic.
0.5 `sync_engine` stays pure Dart. No new dependency without approval.
0.6 On-disk format stays versioned; a breaking layout change bumps the version.

---

## 1. STAGE 1 — SCAFFOLD + HARNESS.  [DONE 2026-09-01]

COVERS: monorepo; `Backend` four-method contract; versioned + CRC-32 op-file
format; `SimulatedBackend` (five faults); `SimulatedDevice`; deterministic
seeded fuzzer + CLI + 1,000-iteration test.
STATE: ops are placeholder bytes; convergence = op-log SET equality.
GATE: 1,000-seed fuzz green.  MET.

## 2. STAGE 2 — CRDT ENGINE CORE.  [IN PROGRESS — fuzz-gated slices]

COVERS: hybrid logical clock (HLC); LWW-register map (fields); OR-set
(collections/tags, add-wins); RGA list (ordered lists); `CrdtEngine implements
SyncEngine`; a structured, versioned operation payload.
CHANGE: `sync()` performs a real merge; the fuzzer emits typed operations, not
random bytes; the convergence check upgrades from op-log set equality to
**byte-identical merged state**.
GATE: merged-state fuzz green; per-CRDT property tests (commutative, idempotent,
associative) pass.

- 2a — HLC + LWW-register map.  [DONE 2026-09-20]
- 2b — OR-set (add-wins).       [DONE 2026-09-21]
- 2c — RGA (ordered lists).     [NEXT]

## 3. STAGE 3 — REAL BACKENDS.  [parallelizable with Stage 2]

COVERS: `sync_backend_fs` (plain/synced folder, atomic writes) first, then
`sync_backend_drive` (Google Drive `appDataFolder`). Same four methods; must
honor the same fault tolerances the harness assumes.
GATE: a real backend drops into the harness / integration tests unchanged.

## 4. STAGE 4 — COMPACTION + SNAPSHOTS.  [PLAN MODE]

COVERS: snapshot + retained op tail (180-day floor); per-device frontier cursor
files; compaction only past the minimum known frontier; full re-bootstrap for a
device staler than the tail; tombstone lifetime = the op tail.
GATE: a device offline past the tail still converges from snapshot; the fuzzer
gains compaction and clock-skew actions.

## 5. STAGE 5 — FLUTTER BINDING.

COVERS: `sync_engine_flutter` — lifecycle-driven sync (resume / background),
`path_provider` local storage, `ChangeNotifier` / `Stream` surfaces; a sample
Android app.
GATE: two devices/emulators sync end-to-end with no data loss.

## 6. STAGE 6 — HARDENING / 1.0.

COVERS: format-migration code (0.x may break; 1.0+ migrates); public API freeze;
docs; `pub.dev` publish; CI running 1k per PR and 100k nightly.
GATE: tagged 1.0.

## 7. POST-1.0 — RICH TEXT CRDT.

COVERS: interleaving anomalies and formatting-span merges. Deliberately deferred
until here. Body text is a single LWW register until this ships (documented
limitation, not a bug).

---

CURRENT POSITION: Stage 2 in progress — slices 2a and 2b done and fuzz-green;
2c (RGA) is next.
