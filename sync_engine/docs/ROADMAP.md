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

## 2. STAGE 2 — CRDT ENGINE CORE.  [DONE 2026-09-21 — fuzz-gated slices]

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
- 2c — RGA (ordered lists).     [DONE 2026-09-21]

## 3. STAGE 3 — REAL BACKENDS.  [IN PROGRESS]

COVERS: `sync_backend_fs` (plain/synced folder, atomic writes) first, then
`sync_backend_drive` (Google Drive `appDataFolder`). Same four methods; must
honor the same fault tolerances the harness assumes.
GATE: a real backend drops into the harness / integration tests unchanged.

- 3a — sync_backend_fs (folder, atomic writes).   [DONE 2026-09-24]
- 3s — public SyncClient + fuzz any Backend.      [DONE 2026-09-24]
- 3b — sync_backend_drive (Drive appDataFolder).  [NEXT — needs dep approval]

NOTE (3a gate): met by a backend contract suite plus a multi-replica
convergence test — replicas share one real folder, author all five operation
types, merge through the real `CrdtEngine`, and must be byte-identical.

NOTE (3s): the device loop (push / pull / confirm-by-readback) moved out of the
test harness into `lib/` as `SyncClient`, over a durable `LocalStore`. The five
faults moved into `FaultyBackend`, a decorator over ANY backend, exported with
the fuzzer from `package:sync_engine/testing.dart`. The fuzzer now drives real
`SyncClient`s, and a crash reopens the client from its store — the production
recovery path. `FsBackend` runs under the full fault fuzzer (100 seeds per
change) and `FsLocalStore` gives apps a durable on-disk store. New fuzz oracle:
an authored stamp must order after every stamp the device holds. The old loop
never advanced its HLC on receive and violated this in 1,000 of 1,000 seeds —
convergence held, but under clock skew a later edit could lose to the one it
replaced. Fixed: the clock absorbs every ingested stamp.

OPEN (found in 3s, not yet fixed):
- HLC drift bound. `receive` trusts remote wall time; one device with a clock
  years ahead drags every device's HLC there permanently. Needs a max-drift
  guard (reject or clamp) — a merge-adjacent change, so plan mode.
- Restart cost. On open every own op is re-verified by download (that is what
  repairs a backend that lost files). O(own ops) per app start until
  compaction (Stage 4) bounds the log, or a persisted confirmation watermark.
- No structured read API. `materialize()` returns canonical bytes, good for
  convergence checks and useless to an app. A typed read model over the fold
  is needed before Stage 5 — it touches the engine, so plan mode.
- Newer operation versions are skipped silently at materialize; DESIGN says
  refuse and surface "update the app".
- 3b: Drive allows two files with one name. The Drive backend must upsert by
  name (update the existing file id); otherwise every re-push adds a copy and
  `download(name)` has no single answer.

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

CURRENT POSITION: Stage 2 complete. Stage 3 in progress — 3a (folder backend)
and 3s (public SyncClient; fault fuzzer runs over real backends) done and
green. Next: 3b (Drive backend, blocked on dependency approval), or Stage 4
(compaction, plan-mode).
