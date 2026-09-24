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
- 3b — sync_backend_drive (Drive appDataFolder).  [BUILT 2026-09-24 — fake
        HTTP only; real-Drive run pending a Cloud project + OAuth client]

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

NOTE (3b): deps `googleapis` + `http` approved 2026-09-24 (`googleapis_auth`
approved but unused: the app hands in an authenticated client). Tested against
`FakeDrive`, an in-memory server behind `MockClient` that speaks the REST
shapes googleapis really sends and injects Drive's own faults — 5xx before a
write, response lost after a write, search lagging behind writes — under the
contract-level `FaultyBackend`. 200 seeds per change; 400 run clean.
Design points the fuzz forced:
- Drive names are not unique. A create whose response is lost, retried while
  search lags, duplicated the file; with the truncated-upload fault on top the
  copies could differ, and a stale copy surfacing after confirmation would
  strand the op on other devices. Fix: create under an id reserved with
  `files.generateIds`, remembered per name, so a retry gets 409 and becomes an
  update. Cross-process duplicates (restart mid-retry) are folded by the next
  upload, and download reads the newest copy.
- The drain must be honest at every layer: `FuzzConfig.onDrain` turns off
  faults injected below the backend. Pinned Drive seed 4 shows why.
Still unverified until run on real Drive: 409 on a reused generated id in
appDataFolder, and modifiedTime ordering of copies. Both are documented API
behaviour; the fake assumes them.

## 4. STAGE 4 — COMPACTION + SNAPSHOTS.  [DONE 2026-09-24]

COVERS: snapshot + retained op tail (180-day floor); per-device frontier cursor
files; compaction only past the minimum known frontier; full re-bootstrap for a
device staler than the tail; tombstone lifetime = the op tail.
GATE: a device offline past the tail still converges from snapshot; the fuzzer
gains compaction and clock-skew actions.

DECIDED (owner, 2026-09-24):
- Snapshots are MERGEABLE CRDT states (a join), one chain per writer
  (`snap_<id>_<gen>.bin`). A stale device catches up by joining them; no
  canonical snapshot, no special re-bootstrap path.
- Tombstones (OR-set remove-tags, RGA tombstone ids) are KEPT FOREVER in v1.
  Dropping them by age is unsafe under join. GC by causal stability is a
  later slice. This amends "tombstone lifetime = the op tail".
- Fuzz secondary invariant: op-log set equality → coverage-set equality
  (snapshot cut ∪ tail keys). Merged-state equality unchanged.
- Remote deletion as written: own op files only, and only when covered by a
  confirmed own snapshot ∧ held by every live device ∧ older than 180 days;
  a device silent > 180 days stops blocking.

- 4a — incremental, joinable CrdtState.          [DONE 2026-09-24]
- 4b — snapshots + local compaction.             [DONE 2026-09-24]
- 4c — cursors, remote deletion, sleeper devices. [DONE 2026-09-24]
- 4d — fs/Drive deletion guards; docs.           [DONE 2026-09-24]

OPEN (after Stage 4):
- Tombstone GC by causal stability (all live cursors cover the removal).
- Restart cost: on open, snapshots are re-joined (one download per writer)
  and own ops re-verified. Persist joined gens / a confirmation watermark.
- Each device keeps one full-state snapshot on the backend: storage is
  N × state size. Fine for a handful of devices.
- A device that uploads ops but never completes a round leaves no cursor
  and blocks remote deletion of others' files until it does (safe; leaks
  storage).
- Retention age of removes / list deletes is inferred from the next op
  that mints a stamp (they carry none of their own).

NOTE (4a): `CrdtState` folds ops incrementally and joins with other states;
its rendered output is byte-identical to the pre-4a fold, checked against a
frozen copy of that fold (`test/support/reference_fold.dart`) on 10,000
random histories. Join is proven commutative, associative, idempotent, and
equal to the fold of the union, including after pruning and a codec round
trip. SyncClient no longer re-folds the log per call or rescans it per edit.
The fuzzer also asserts incremental state == a fresh fold of each log.

NOTE (4b): `snap_<id>_<gen>.bin` (magic HSS1, versioned, CRC) carries a
writer's full state and its cut vector. `SyncClient.compact()` saves it as the
local snapshot, drops covered pulled ops from the store, and publishes it,
confirmed by readback. Pull joins each writer's newest readable snapshot
BEFORE fetching ops, so a new device downloads the snapshot plus the tail,
not the history. Gens persist before upload and are never reused. Own ops stay
in the local log until 4c deletes them remotely. Fuzz: a compact action (3%
of steps); coverage-set equality replaces op-log set equality (approved);
every store must reopen to the state its device holds. Logs shrank in 299 of
300 seeds. Mutants caught: join skipping the state, open ignoring the local
snapshot, local compaction shedding own ops. Limitation until 4c: no op file
is ever deleted from the backend, so a device that loses track of snapshot
coverage can heal by re-downloading — some snapshot bugs only show in 4c.

NOTE (4c): `cursor_<id>.bin` (HSC1) announces a device's DURABLE frontier and
its clock; it is queued before the push so the same round confirms it.
`compact()` then deletes own op files below min(confirmed own snapshot cut,
retention age limit, every live device's cursor), and superseded own
snapshots. A device whose cursor is older than the retention window stops
blocking; an unreadable cursor counts as holding nothing. New fault:
droppedDelete. Fuzz: 30 ms retention, a sleeper device in a third of runs
(syncs early, then offline while others compact and delete), counts of
deleted op files; 3,000 seeds green, deletion in ~65% of runs including past
sleepers. The Stage 4 GATE ("a device offline past the tail still converges
from snapshot") is met by fuzz and by a deterministic test.
As predicted by the snapshot design, skipping the frontier gate does NOT
break convergence (it only changes retained history) — the gate is policy,
tested by unit tests. Mutants caught: trusting a snapshot upload without
readback; deleting the newest confirmed snapshot; deleting beyond the
confirmed cut (unit test — the fuzz masks it when other devices' snapshots
cover the same ops); ignoring cursors; no dead-device rule.

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

CURRENT POSITION: Stages 1, 2 and 4 complete. Stage 3: 3a, 3s done; 3b (Drive)
built and fuzz-green against a fake Drive, real-Drive verification deferred
by the owner. Next: real-Drive check when credentials exist; Stage 5 (Flutter
binding) needs the structured read API first (plan mode: touches the
engine).
