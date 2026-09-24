# hellsyncie

Offline-first data sync for Dart and Flutter apps. No server.

Read this before writing code against it. Sections are numbered. Notes marked
**NOTE** are advisory. Notes marked **WARNING** protect data integrity.

---

## 1. WHAT THIS IS (plain terms)

1.1 hellsyncie is a library. App developers add it to keep one user's data the
    same across that user's phone, tablet, and laptop.

1.2 It uses no server. It uses storage the user already owns - a Google Drive
    folder, a plain folder, an S3 bucket - as a shared drop box. Devices leave
    files there and pick up each other's files.

1.3 It never shows a merge conflict. Two devices may edit the same data while
    both are offline for months. When they reconnect, all devices arrive at the
    identical result with no prompt and no lost log.

1.4 Analogy. Not one shared document that devices overwrite in turn. Instead,
    each device keeps its own append-only notebook of changes and copies every
    other notebook. Because each change names a stable thing ("the item with id
    A:46"), the notebooks can be replayed in any order and reconstruct the same
    picture.

---

## 2. PRINCIPLE OF OPERATION

2.1 One log per device. Each device appends its changes to its own file set and
    writes ONLY its own files. No file is ever written by two devices.

    **WARNING** This is the safety rule the whole design rests on. Because no
    two devices share a file, the storage layer cannot produce a write
    collision. Do not break it.

2.2 Sync is: list the shared storage, download the change-files you have not
    seen, apply them locally. That is all a sync round does.

2.3 Convergence is guaranteed by CRDTs (Conflict-free Replicated Data Types).
    Any set of changes, applied in any order, folds to identical state on every
    device. No arbitration, no "which copy wins" dialog.

2.4 Change-files are immutable and checksummed. A corrupt or half-written file
    is skipped and fetched again, never partly applied. Applying the same file
    twice does nothing (changes are keyed by device id + sequence number).

2.5 Clocks are hybrid logical clocks, not wall clocks. Wall clocks drift; a
    device may sit offline for months. Ordering never trusts wall time.

    **NOTE** Full design and rejected alternatives: `sync_engine/docs/DESIGN.md`.

---

## 3. WHAT IT DOES / DOES NOT DO

3.1 DOES:
    - Sync a single user's data across their own devices, server-free.
    - Work fully offline; converge on reconnect with no data loss.
    - Tolerate dumb, unreliable storage (stale listings, partial uploads,
      files that appear late or twice, uploads that silently vanish).
    - Store data in storage the user controls (privacy by construction).

3.2 DOES NOT (by decision, this stage):
    - Live co-editing. Sync is by cycle (list, download, merge), not keystroke.
    - Shared rich-text documents. Deferred until version 1.0.
    - Many-writer / large multi-user datasets. Tuned for one person's devices.

    **NOTE** Data types decided and fixed until 1.0: LWW-register maps (fields),
    OR-sets (collections/tags), RGA lists (ordered lists). Body text is a single
    last-write-wins register for now; concurrent edits to it lose one side.

---

## 4. HOW IT IS BUILT

4.1 Build order is deliberate. The test harness is built BEFORE the sync engine.
    The harness is a torture chamber; the engine is built inside it.

4.2 Stage 1 - SHIPPED: the harness.
    - The storage contract (`Backend`: list, download, upload, delete).
    - The versioned, checksummed change-file format.
    - A fault layer that makes any backend exhibit five real storage faults
      on demand.
    - Simulated devices (durable log, upload-retry, crash/restart).
    - A deterministic fuzzer: N devices, random changes, random sync order,
      random faults - one seed reproduces an entire run exactly.

4.3 Stage 2 - SHIPPED: the CRDT engine (the merge logic), behind one
    interface, `SyncEngine`.
    - Hybrid logical clock for ordering.
    - LWW-register maps, OR-sets (add-wins), RGA ordered lists.
    - The fuzzer asserts byte-identical MERGED state on every device.

4.4 Stage 3 - IN PROGRESS: real storage backends.
    - `sync_backend_fs` - plain or desktop-synced folder, atomic writes, plus
      a durable on-disk local store. SHIPPED.
    - `SyncClient` - the device-side sync loop as a public, pure-Dart API.
      The fault fuzzer drives it over any backend, the real folder included.
      SHIPPED.
    - `sync_backend_drive` - Google Drive appDataFolder. Next.

    **NOTE** Live build status is kept in `sync_engine/docs/ROADMAP.md`.

4.5 Testing doctrine (hard rules, see `CLAUDE.md`):
    - Every engine change runs the fuzz suite: 1,000 seeds per change.
    - A failing seed means a real bug. Fix the engine. Never weaken the
      convergence check. Never delete a failing assertion.
    - Failing seeds are pinned forever in
      `sync_engine/packages/sync_engine/test/regression_seeds.dart`.

    **NOTE** This discipline already caught a transport bug during the first
    build (a truncated upload was confirmed by name and never re-sent). It was
    fixed by verifying the stored bytes read back intact before trusting them.

---

## 5. BUILD AND RUN (current state)

5.1 Requirement: Dart SDK 3.6 or newer. Check with `dart --version`.

5.2 Resolve the workspace. From `sync_engine/`:

```bash
dart pub get
```

5.3 Run the full test suite (unit tests + 1,000-seed convergence run). From
    `sync_engine/packages/sync_engine/`:

```bash
dart test
```

    Run the folder-backend tests (contract, multi-replica convergence, and
    100 fault-fuzz seeds over a real shared folder) the same way, from
    `sync_engine/packages/sync_backend_fs/`.

5.4 Run the fuzzer directly. From `sync_engine/packages/sync_engine/`:

```bash
dart run test/harness/fuzz.dart --seed=1
```

5.5 Reproduce a failure and see the seed-replay workflow. A forced 100% fault
    guarantees a divergence; the seed is printed and per-device logs are dumped
    to `.fuzz_failures/seed_<seed>/`:

```bash
dart run test/harness/fuzz.dart --seed=7 --force-fault=dropped:1.0
```

5.6 Optional monorepo tooling (Melos is pre-approved; pub workspaces already
    bootstrap without it):

```bash
dart pub global activate melos
```

---

## 6. VALUE ACROSS DIMENSIONS

6.1 For the app maker / business:
    - No sync server to build, pay for, scale, or wake up for at 3 a.m.
    - Sync - normally a deep, error-prone build - arrives as a library proven
      by a fuzz suite.
    - One dependency reused across an entire app portfolio.

6.2 For the end user:
    - Data lives in the user's own storage. The app maker cannot read, sell, or
      lose it. If the company folds, the data is still the user's.
    - True offline use. Edit for hours on a plane or months on a dormant phone;
      it reconciles correctly on reconnect.
    - No data loss, no conflict pop-ups.

6.3 For technical robustness:
    - Assumes storage lies, and is tested against exactly those lies.
    - Append-only log is a complete history - free version history.
    - Every failure is reproducible from a single seed.
    - Storage layer is four methods, so the same engine runs over a folder, S3,
      Drive, or anything else with no rewrite.

6.4 Poor fit (choose another tool):
    - Real-time collaboration on shared documents.
    - Large multi-user datasets with heavy concurrent writes.

---

## 7. WHERE IT IS VALUABLE / HOW IT IS USED

7.1 Users of the library are app developers. End users never see it; they only
    experience an app whose data is the same everywhere and never loses edits.

7.2 Sweet spot: single-user, personal, offline-capable apps across a handful of
    the user's own devices - notes, journals, task and habit trackers, reading
    lists, budgets, personal wikis.

7.3 Integration shape (any app):
    1. Pick a backend (folder, Drive, S3).
    2. Declare your data as the provided CRDT types.
    3. Call sync on a schedule and on reconnect.
    The library handles fault tolerance, ordering, and convergence.

---

## 8. FLUTTER (ANDROID) INTEGRATION

**NOTE** The merge engine (Stage 2), the folder backend (Stage 3a), and the
pure-Dart `SyncClient` have shipped. The Drive backend (Stage 3b) and the
Flutter binding (Stage 5) have not, per §4. The steps below are the TARGET integration - the intended, stable
shape of the API - so an app team can plan against it now. Names may tighten
before 1.0.

8.1 Add dependencies. In the app's `pubspec.yaml`:

```yaml
dependencies:
  sync_engine:
  sync_engine_flutter:
  sync_backend_drive:   # or sync_backend_fs for a plain/synced folder
```

8.2 Android manifest. For the Google Drive backend, the app authenticates the
    user's own Drive; it needs network access. In
    `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

    **NOTE** Drive uses the hidden per-app `appDataFolder`. It is private to the
    app, invisible in the user's Drive UI, and needs no broad storage
    permission. Sign-in is the user's own Google account via the standard
    consent screen - you do not build or host anything.

8.3 Open a store on app start. Target API:

```dart
import 'package:sync_engine/sync_engine.dart';
import 'package:sync_engine_flutter/sync_engine_flutter.dart';
import 'package:sync_backend_drive/sync_backend_drive.dart';

// One stable id per install, generated once and persisted on-device.
final backend = DriveBackend(appDataFolder: true);
final store = await SyncStore.open(
  backend: backend,
  deviceId: await SyncStore.loadOrCreateDeviceId(),
);
```

8.4 Declare data as CRDT types. Target API:

```dart
// A note: title is a last-write-wins field; tags are an add-wins set;
// checklist items are an ordered (RGA) list.
final note = store.document('note:42');
note.field('title').set('Groceries');
note.set('tags').add('home');
final items = note.list('items');
items.insert(0, 'Milk');
```

    **WARNING** Do not store the body of a document as one field if two devices
    may edit it at once - one side's edit is dropped by design at this stage.
    Rich-text merge is deferred to 1.0.

8.5 Sync. Target API - call after local edits, on reconnect, and on resume:

```dart
await store.sync();        // one round: push local, pull remote, converge

// React to changes arriving from other devices:
store.changes.listen((_) => setState(() {}));
```

8.6 Background / lifecycle (Android). Trigger `store.sync()`:
    - on `AppLifecycleState.resumed`,
    - on a connectivity-restored event,
    - optionally on a periodic background task (e.g. WorkManager) for
      quiet catch-up.

    **NOTE** Sync is safe to call often and safe to interrupt. A killed sync
    loses nothing; the local log is durable and the next round resumes.

8.7 What you can do TODAY, in pure Dart (CLI, desktop, server-side tests):

```dart
import 'dart:convert';
import 'dart:io';
import 'package:sync_backend_fs/sync_backend_fs.dart';
import 'package:sync_engine/sync_engine.dart';

final client = await SyncClient.open(
  backend: FsBackend(Directory('/path/to/Dropbox/myapp')), // shared folder
  store: FsLocalStore(Directory('/path/to/app-data/sync')), // this device
); // device id: generated once, kept in the store

await client.put('note:42', 'title', utf8.encode('Groceries'));
final milk = await client.insertIntoList('note:42', 'items', utf8.encode('Milk'));
await client.insertIntoList('note:42', 'items', utf8.encode('Eggs'), after: milk);
await client.sync(); // push, pull, confirm by readback
```

    **WARNING** Never copy a local store directory to another device. The
    device id inside must stay unique to one install.

    **NOTE** Reading state back is not yet typed: `materialize()` returns the
    canonical merged bytes. A structured read API is an open roadmap item.

    Writing a backend of your own? Prove it under the same fault fuzzer:

```dart
import 'package:sync_engine/testing.dart';

final result = await runFuzz(seed, backend: MyBackend(emptyStorage));
```

---

## 9. REPOSITORY LAYOUT

```
hellsyncie/
  README.md                     this file
  CLAUDE.md                     project rules (hard)                  [under sync_engine/]
  docs/DESIGN.md                full design + rejected alternatives   [under sync_engine/]
  docs/ROADMAP.md               staged build plan + live status       [under sync_engine/]
  docs/session-01-brief.md      original build brief (if preserved)
  sync_engine/                  monorepo (workspace) root
    pubspec.yaml                pub workspace
    melos.yaml                  optional monorepo scripts
    packages/
      sync_engine/              pure Dart: contract, format, engine,  [SHIPPED]
                                SyncClient; testing.dart = fuzzer
      sync_engine_flutter/      Flutter binding                        [stub]
      sync_backend_fs/          folder backend + on-disk local store   [SHIPPED]
      sync_backend_drive/       Google Drive backend                   [stub]
```

**NOTE** `CLAUDE.md` and `docs/DESIGN.md` currently sit under `sync_engine/`.
The original brief places them at the repository root; moving them there is a
safe future tidy-up.
