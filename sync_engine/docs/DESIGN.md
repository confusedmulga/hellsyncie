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
- tombstones live as long as the op tail

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