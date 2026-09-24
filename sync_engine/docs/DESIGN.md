# DESIGN.md — sync_engine

## Problem
Sync app data across a user's devices using only dumb file storage
(Drive appDataFolder, plain folder, S3). No server, no coordination,
no user-facing conflict resolution. Devices edit offline for arbitrary
periods and must converge deterministically.

## Core decision: op log, not state sync

Naive approach: store state.json in shared storage. Fails because two
offline devices both upload; last write destroys the other's edits.
Diff-and-merge on state files requires three-way merge with a common
ancestor, which dumb storage can't track reliably, and merge conflicts
surface to the user — unacceptable.

Chosen approach: append-only op logs. Each device writes ONLY its own
files (ops_<deviceId>_<seq>.bin). No file is ever written by two
devices, so storage-level conflicts are structurally impossible. Sync =
list, download unseen op files from other devices, merge locally.

## Why CRDTs for merge

Ops reference stable identities, not positions. "Insert after element
with ID A:46" is unambiguous regardless of concurrent edits. CRDT
semantics guarantee: any set of ops, applied in any order (subject to
causal delivery per device via seq numbers), converges to identical
state on every device. No arbitration needed.

Chosen types (fixed until 1.0):
- LWW-register map — document fields (title, timestamps, settings).
  Tie-break: (HLC timestamp, deviceId). Accepted trade-off: concurrent
  field edits lose one write. Fine for scalars; NOT fine for text.
- OR-set — tags, collections, membership. Add wins over concurrent
  remove. Chosen over 2P-set because re-adding must work.
- RGA list — ordered lists (blocks, checklist items).
- Rich text CRDT — OUT OF SCOPE until 1.0. Interleaving anomalies and
  formatting-span merges are the deep end. Body text is a single LWW
  register initially: concurrent body edits lose one side. Documented
  limitation, not a bug.

## Clocks
Hybrid logical clocks (HLC), not wall clocks. Wall clocks skew; devices
sit offline for months. HLC gives causality-consistent ordering with
bounded drift from physical time. deviceId breaks ties. Never trust
wall-clock comparison across devices for anything correctness-related.

The clock absorbs (HLC receive) every stamp a device ingests, so an op
authored after seeing another op always orders after it. Convergence does
not need this; intent does. Without it a slow-clocked device's later field
write loses to the write it replaced, and its list insert lands after
siblings it meant to precede. The fuzzer asserts it on every authored op.
The clock is not stored: on open it restarts at the highest stamp in the
local log.

## Device side (SyncClient)
- Persist before publish: an op reaches the LocalStore before it can be
  uploaded. Otherwise a crash after upload lets the device reuse that seq
  for a different op.
- Confirm by readback: an own op counts as published only when it downloads
  back with an identical payload. Until then it is re-uploaded every round.
- Device ids are random per LocalStore and never reused. A wiped store is a
  new device. Defense in depth for stores that lose their tail anyway: own
  files found on the backend but missing locally are re-adopted (the seq
  counter moves past them), and the first round after open pulls before it
  pushes, so a readback that differs from the local op
  (DeviceIdCollisionException) stops the device before it overwrites
  anything. A stale listing can hide the evidence, so this is detection,
  not a guarantee; unique ids are the guarantee.

## Storage backend contract
Four methods: list, download, upload, delete. Everything else lives
above this line.

Backends LIE. Design assumes:
- list() may return stale snapshots (Drive does this)
- upload may partially persist then report failure (truncated file)
- upload may report success and persist nothing
- a file may be listed twice or invisible for a while after upload

Consequences:
- op files are immutable once written; never appended or rewritten
- every op file carries a checksum + format version header; corrupt or
  truncated files are skipped and re-fetched, never partially applied
- merge is idempotent: applying the same op file twice is a no-op
  (op IDs are (deviceId, seq); duplicates ignored)
- missing files are tolerated: seq gaps mean "not visible yet", sync
  retries later; nothing assumes list() is complete

## Compaction (the tombstone problem)
Op logs grow forever; deletes leave tombstones. Compaction squashes old
ops into a snapshot. Danger: a device offline for six months syncs
against compacted history and can't reconstruct state.

Policy (owner decision, model does not change these numbers):
- snapshot + retain full op tail covering the last N days (default 180)
- devices announce their sync frontier in a small per-device cursor file
- ops are only compacted past the minimum frontier across known devices,
  with the 180-day floor as backstop
- a device staler than the retained tail gets a full re-bootstrap from
  snapshot; its unsynced local ops are still valid (op-based, replayed
  on top)
- ~~tombstones live as long as the op tail~~ AMENDED 2026-09-24 (owner):
  tombstones are kept forever in v1; see below.

As built (Stage 4, owner-approved 2026-09-24):
- A snapshot is the merged CRDT STATE (LWW registers with their stamps,
  OR-set add/remove tags, RGA nodes with anchors and tombstones), not the
  rendered document. States join: join(fold A, fold B) = fold(A ∪ B).
  That one property does most of the work:
  - "re-bootstrap" is just a join — a stale or new device joins the newest
    snapshots it sees and pulls the tail; no special path;
  - no canonical snapshot is needed. Each device writes its own chain,
    `snap_<id>_<gen>.bin`; a newer gen contains everything an older one
    did, and an older gen is deleted only after a newer one is confirmed;
  - snapshots are fetched before op files, so the ops they cover are
    never downloaded.
- Pruning is limited to what no join can undo: LWW keeps winners, an
  OR-set add-tag goes once a remove-tag cancels it, a deleted RGA element
  loses its value. Remove-tags and RGA tombstone ids stay FOREVER (v1):
  dropping them by age would let a device or old snapshot still carrying
  the add resurrect the item. GC by causal stability is future work.
- Remote deletion: a device deletes only its OWN op files, only below
  min(cut of its snapshot confirmed on the backend by readback, retention
  age, every live device's cursor). Correctness needs only the first term;
  the other two are the retained-history policy above. A device whose
  cursor is older than the retention window no longer blocks.
- Cursors (`cursor_<id>.bin`) announce only what is DURABLE locally, so a
  crash can never make a device hold less than it claimed.
- File kinds, all versioned + CRC: op files (HSY1), snapshots (HSS1),
  cursors (HSC1). Op files and snapshots are immutable per name; a cursor
  is the one file a device overwrites.

## Format versioning
Every file has a version byte. Reading a higher version than supported =
refuse and surface "update the app", never guess. Breaking format
changes bump the version; 0.x may break, 1.0+ requires migration code.

## Testing doctrine
Harness before engine. All correctness claims rest on the fuzz suite:
randomized devices/ops/sync-order/faults, seeded, deterministic replay.
Convergence assertions are never weakened. Failing seeds become
permanent regression tests. CI: 1k iterations per PR, 100k nightly.

## Explicitly rejected alternatives
- State-based CRDTs (delta or full): simpler merge but requires
  shipping full state or delta bookkeeping; op logs fit immutable-file
  storage better and give free history.
- Automerge/Yjs FFI bindings: drags native builds into every consumer
  app, kills pub.dev adoption, and their sync protocols assume a relay.
- Git-style three-way merge: needs ancestor tracking storage can't
  provide; surfaces conflicts.
- Per-note whole-file LWW: silent data loss, the thing we're replacing.