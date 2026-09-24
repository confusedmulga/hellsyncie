import 'dart:math';
import 'dart:typed_data';

import 'backend.dart';
import 'crdt_state.dart';
import 'format.dart';
import 'hlc.dart';
import 'local_store.dart';
import 'op.dart';
import 'op_codec.dart';
import 'operation.dart';
import 'operation_codec.dart';
import 'snapshot.dart';

/// Thrown by [SyncClient] when the backend holds a DIFFERENT op under an
/// identity this device also authored: two stores are writing under one
/// device id. Continuing would overwrite ops other devices already merged.
///
/// Stop syncing this store. Recover by opening a fresh store (which draws a
/// fresh device id) and re-bootstrapping from the backend.
class DeviceIdCollisionException implements Exception {
  DeviceIdCollisionException(this.deviceId, this.fileName);

  final String deviceId;
  final String fileName;

  @override
  String toString() => 'DeviceIdCollisionException: $fileName on the backend '
      'is not the op device $deviceId authored under that name. Another store '
      'is writing under this device id; open a fresh store.';
}

/// Outcome of one [SyncClient.sync] round.
class SyncResult {
  const SyncResult({required this.received, required this.pending});

  /// Ops and snapshots ingested from the backend this round. Non-zero means
  /// the materialized state may have changed.
  final int received;

  /// This device's ops (and snapshot) not yet confirmed intact on the
  /// backend. They are re-uploaded every round until a readback matches.
  final int pending;
}

/// The device side of sync: authors ops into a durable [LocalStore], pushes
/// them to a [Backend], pulls everyone else's, and materializes merged state.
///
/// Pure Dart. The backend is assumed to lie in every way the [Backend] docs
/// list; the client never trusts an upload's return value. An own op counts as
/// published only once it DOWNLOADS back from the backend byte-for-byte equal
/// in payload — a truncated upload leaves a corrupt file under the right name,
/// so trusting the listing alone would strand the full copy forever.
///
/// Every op is persisted locally BEFORE it can be uploaded. Otherwise a crash
/// between upload and persist would let the device reuse that sequence number
/// for a different op after restart.
///
/// The hybrid logical clock absorbs every stamp the device ingests, so an op
/// authored after seeing another device's op always orders after it, however
/// skewed the wall clocks. Without that, a slow-clocked device's later field
/// write loses to the write it was replacing, and its list insert lands after
/// siblings it was meant to precede.
class SyncClient {
  SyncClient._(
    this.deviceId,
    this._backend,
    this._store,
    this._physicalMillis,
  ) : _clock = Hlc.zero(deviceId);

  /// Open a client over [store], loading its durable op log.
  ///
  /// [deviceId] defaults to the id saved in [store], or a fresh random one
  /// for a fresh store. A device id must never be shared by two stores: pass
  /// one explicitly only when you can guarantee that. Passing an id that
  /// differs from the one saved in [store] throws [StateError].
  ///
  /// [physicalMillis] is the wall-clock source (millis since epoch); inject a
  /// deterministic one in tests. [random] seeds device-id generation.
  static Future<SyncClient> open({
    required Backend backend,
    required LocalStore store,
    String? deviceId,
    int Function()? physicalMillis,
    Random? random,
  }) async {
    final saved = await store.loadDeviceId();
    final id = deviceId ?? saved ?? _newDeviceId(random ?? Random.secure());
    if (!OpFileFormat.isValidDeviceId(id)) {
      throw ArgumentError.value(id, 'deviceId', 'not a valid device id');
    }
    if (saved != null && saved != id) {
      throw StateError('store belongs to device $saved, not $id');
    }
    if (saved == null) await store.saveDeviceId(id);

    final client = SyncClient._(
      id,
      backend,
      store,
      physicalMillis ?? () => DateTime.now().millisecondsSinceEpoch,
    );
    client._load(await store.loadSnapshot(), await store.loadOps());
    return client;
  }

  /// This device's id. Every op file it writes carries it.
  final String deviceId;

  final Backend _backend;
  final LocalStore _store;
  final int Function() _physicalMillis;

  Hlc _clock;
  int _nextSeq = 0;
  final List<Op> _log = <Op>[];
  final Set<String> _keys = <String>{}; // op keys already in _log

  /// Everything held — snapshots joined plus every op in [_log] — folded.
  /// Updated as ops arrive, never re-folded.
  final CrdtState _state = CrdtState();

  /// Per author, a count of ops covered by a snapshot folded into [_state]:
  /// every op of that author with a lower seq is held, even if not in [_log].
  final Map<String, int> _base = <String, int>{};

  /// Highest snapshot gen joined, per writer. A writer's newer gen contains
  /// everything its older ones did, so older gens are never fetched.
  final Map<String, int> _joinedGen = <String, int>{};

  /// Highest own snapshot gen used. Persisted in the local snapshot BEFORE a
  /// gen is uploaded, so a gen number never names two different snapshots.
  int _gen = 0;

  /// Own snapshot uploaded but not yet confirmed by readback.
  ({String name, Uint8List bytes, int gen})? _pendingSnapshot;

  /// Highest own snapshot gen confirmed intact on the backend since open.
  int _confirmedGen = 0;

  bool _compactRequested = false;

  /// Own ops not yet confirmed intact on the backend, by file name. Transient:
  /// on open every own op is re-queued, so a backend that lost files is
  /// repaired by the next round.
  final Map<String, Op> _unconfirmed = <String, Op>{};

  /// Whether a pull has completed since open. Until one has, nothing is
  /// uploaded: the first look at the backend is what detects a device-id
  /// collision before this device overwrites anything.
  bool _pulledSinceOpen = false;

  /// Serializes changes to the log and sequence counter: authoring and pull
  /// ingestion never interleave across their store writes.
  Future<void> _mutex = Future<void>.value();

  Future<SyncResult>? _running;
  Future<SyncResult>? _queued;

  /// Ops held individually, in local arrival order: every own op, and pulled
  /// ops not yet folded into a snapshot. See [frontier] for all that is held.
  List<Op> get ops => List<Op>.unmodifiable(_log);

  /// Per author, how many of its ops this device holds contiguously from seq
  /// 0 — in a snapshot or in [ops]. Authors with none are omitted.
  Map<String, int> get frontier {
    final out = <String, int>{};
    for (final a in <String>{
      ..._base.keys,
      for (final op in _log) op.deviceId
    }) {
      var k = _base[a] ?? 0;
      while (_keys.contains('$a#$k')) {
        k++;
      }
      if (k > 0) out[a] = k;
    }
    return out;
  }

  /// Own snapshot gen confirmed intact on the backend since open; 0 if none.
  int get confirmedSnapshotGen => _confirmedGen;

  /// The device's hybrid logical clock: at or above every stamp it holds.
  Hlc get clock => _clock;

  /// Own ops (and snapshot) not yet confirmed on the backend.
  int get pendingUploads =>
      _unconfirmed.length + (_pendingSnapshot == null ? 0 : 1);

  /// The merged state of everything held. Byte-identical on every device
  /// holding the same op set, whether as ops or folded into snapshots.
  Uint8List materialize() => _state.serialize();

  /// Ids of every element ever inserted into the list [listField] of [docId],
  /// deleted ones included, ascending: valid anchors for [insertIntoList].
  List<Hlc> listElementIds(String docId, String listField) =>
      _state.elementIds(docId, listField);

  // --- authoring ---

  /// Set [field] of [docId] (LWW register).
  Future<void> put(String docId, String field, Uint8List value) => _author(
      () => MapPut(docId: docId, field: field, value: value, hlc: _tick()));

  /// Add [element] to the OR-set [setField] of [docId].
  Future<void> addToSet(String docId, String setField, Uint8List element) =>
      _author(() => SetAdd(
            docId: docId,
            setField: setField,
            element: element,
            tag: _tick(),
          ));

  /// Remove [element] from the OR-set [setField] of [docId]. Cancels exactly
  /// the adds this device has seen; a concurrent unseen add survives. A no-op
  /// (nothing authored) if this device has seen no add of [element].
  Future<void> removeFromSet(
    String docId,
    String setField,
    Uint8List element,
  ) =>
      _author(() {
        final observed = _state.addTagsFor(docId, setField, element);
        if (observed.isEmpty) return null;
        return SetRemove(
          docId: docId,
          setField: setField,
          element: element,
          observedTags: observed,
        );
      });

  /// Insert [value] into the RGA list [listField] of [docId], immediately
  /// after element [after] (null = head). Returns the new element's id.
  Future<Hlc> insertIntoList(
    String docId,
    String listField,
    Uint8List value, {
    Hlc? after,
  }) async {
    late Hlc id;
    await _author(() => ListInsert(
          docId: docId,
          listField: listField,
          id: id = _tick(),
          after: after,
          value: value,
        ));
    return id;
  }

  /// Delete (tombstone) element [elementId] of the RGA list [listField].
  Future<void> removeFromList(String docId, String listField, Hlc elementId) =>
      _author(() => ListDelete(
            docId: docId,
            listField: listField,
            elementId: elementId,
          ));

  Hlc _tick() => _clock = _clock.send(_physicalMillis());

  Future<void> _author(Operation? Function() build) => _exclusive(() async {
        final operation = build();
        if (operation == null) return;
        final op = Op(deviceId, _nextSeq, OperationCodec.encode(operation));
        await _store.appendOps(<Op>[op]); // durable BEFORE it can be uploaded
        _nextSeq = op.seq + 1; // a failed append consumes no sequence number
        _keys.add(op.key);
        _log.add(op);
        _state.apply(operation);
        _unconfirmed[OpFileFormat.fileName(deviceId, op.seq)] = op;
      });

  Future<T> _exclusive<T>(Future<T> Function() body) {
    final result = _mutex.then((_) => body());
    _mutex = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  // --- sync ---

  /// One round: push unconfirmed own ops, then pull (the first round after
  /// open pulls before it pushes). Safe to call often and concurrently: calls
  /// made while a round runs share one follow-up round, which starts after the
  /// current one and so includes their edits.
  ///
  /// Throws what [Backend.list] or the [LocalStore] throws; the round is
  /// abandoned and the next call retries. Upload and download failures are
  /// absorbed and retried. Throws [DeviceIdCollisionException] as described
  /// there.
  Future<SyncResult> sync() {
    final queued = _queued;
    if (queued != null) return queued;
    final running = _running;
    if (running == null) {
      return _running = _round().whenComplete(() => _running = null);
    }
    return _queued = running.then<void>((_) {}, onError: (Object _) {}).then(
      (_) {
        _queued = null;
        return sync();
      },
    );
  }

  /// A sync round that also compacts: saves the whole state as the local
  /// snapshot, drops the pulled ops it covers from the local store, and
  /// publishes it as `snap_<deviceId>_<gen>` — confirmed, like ops, only by
  /// reading it back intact.
  Future<SyncResult> compact() {
    _compactRequested = true;
    return sync();
  }

  Future<SyncResult> _round() async {
    var received = 0;
    if (!_pulledSinceOpen) received += await _pull();
    if (_compactRequested) {
      _compactRequested = false;
      await _exclusive(_publishSnapshot);
    }
    await _push();
    received += await _pull();
    return SyncResult(received: received, pending: pendingUploads);
  }

  Future<void> _push() async {
    for (final MapEntry(key: name, value: op)
        in _unconfirmed.entries.toList()) {
      try {
        await _backend.upload(name, OpCodec.encode(op));
      } on Object {
        // Failed or truncated: stays unconfirmed, re-pushed next round.
      }
    }
    final snap = _pendingSnapshot;
    if (snap != null) {
      try {
        await _backend.upload(snap.name, snap.bytes);
      } on Object {
        // Re-pushed next round.
      }
    }
  }

  /// List; join the newest unjoined snapshot of each writer; confirm own
  /// uploads by readback; download the op files no snapshot covers; ingest.
  Future<int> _pull() async {
    final names = <String>{for (final f in await _backend.list()) f.name};

    // Snapshots first, so the op files they cover are never downloaded.
    final unjoined = <String, List<int>>{}; // writer -> gens newer than joined
    for (final name in names) {
      final snap = SnapshotFormat.parseFileName(name);
      if (snap == null) continue;
      if (snap.writer == deviceId && snap.gen > _gen) _gen = snap.gen;
      if (name == _pendingSnapshot?.name) {
        await _confirmSnapshot();
      } else if (snap.gen > (_joinedGen[snap.writer] ?? 0)) {
        (unjoined[snap.writer] ??= <int>[]).add(snap.gen);
      }
    }
    // Newest first: it holds everything older gens did. Fall back only if it
    // is unreadable (a truncated upload its writer has not yet replaced).
    final snapshots = <Snapshot>[];
    final covered = Map<String, int>.of(_base);
    for (final MapEntry(key: writer, value: gens) in unjoined.entries) {
      gens.sort((a, b) => b.compareTo(a));
      for (final gen in gens) {
        final s = await _fetchSnapshot(writer, gen);
        if (s == null) continue;
        snapshots.add(s);
        s.cut.forEach((a, n) {
          if (n > (covered[a] ?? 0)) covered[a] = n;
        });
        break;
      }
    }

    final fetched = <Op>[];
    for (final name in names) {
      final id = OpFileFormat.parseFileName(name);
      if (id == null) continue;
      final mine = _unconfirmed[name];
      if (mine != null) {
        await _confirm(name, mine);
      } else if (id.seq >= (covered[id.deviceId] ?? 0) &&
          !_keys.contains('${id.deviceId}#${id.seq}')) {
        // Another device's op — or our own that this store lost; re-adopting
        // it moves our sequence counter past it so it is never reused.
        final op = await _fetch(name, '${id.deviceId}#${id.seq}');
        if (op != null) fetched.add(op);
      }
    }
    final received = await _ingest(fetched, snapshots);
    _pulledSinceOpen = true;
    return received;
  }

  Future<void> _confirm(String name, Op mine) async {
    final Op stored;
    try {
      stored = OpCodec.decode(await _backend.download(name));
    } on Object {
      return; // missing, truncated, or corrupt: stays queued for re-push
    }
    if (stored.key != mine.key) return; // wrong content under our name
    if (!_bytesEqual(stored.payload, mine.payload)) {
      throw DeviceIdCollisionException(deviceId, name);
    }
    _unconfirmed.remove(name);
  }

  Future<void> _confirmSnapshot() async {
    final pending = _pendingSnapshot!;
    try {
      if (!_bytesEqual(await _backend.download(pending.name), pending.bytes)) {
        return; // truncated or stale: re-pushed next round
      }
    } on Object {
      return;
    }
    _pendingSnapshot = null;
    if (pending.gen > _confirmedGen) _confirmedGen = pending.gen;
  }

  /// Download and decode [name], or null if unreadable or not the op its name
  /// claims. Skipped files are not remembered, so they are retried next pull.
  Future<Op?> _fetch(String name, String key) async {
    try {
      final op = OpCodec.decode(await _backend.download(name));
      return op.key == key ? op : null;
    } on Object {
      return null;
    }
  }

  Future<Snapshot?> _fetchSnapshot(String writer, int gen) async {
    try {
      final s = Snapshot.decode(
          await _backend.download(SnapshotFormat.fileName(writer, gen)));
      return s.writer == writer && s.gen == gen ? s : null;
    } on Object {
      return null;
    }
  }

  Future<int> _ingest(List<Op> fetched, List<Snapshot> snapshots) =>
      _exclusive(() async {
        final before = _state.maxStamp;
        var joined = 0;
        for (final s in snapshots) {
          if (s.gen <= (_joinedGen[s.writer] ?? 0)) continue;
          _state.join(s.state);
          _raiseBase(s.cut);
          _joinedGen[s.writer] = s.gen;
          joined++;
        }
        // A snapshot may cover own ops this store lost: never reuse those.
        _nextSeq = max(_nextSeq, _base[deviceId] ?? 0);

        final fresh = <Op>[];
        for (final op in fetched) {
          if (_keys.contains(op.key)) {
            if (op.deviceId != deviceId) continue;
            // Authored locally while this pull ran, yet a different op
            // already sits under that identity on the backend.
            final own = _log.firstWhere((o) => o.key == op.key);
            if (!_bytesEqual(own.payload, op.payload)) {
              throw DeviceIdCollisionException(
                  deviceId, OpFileFormat.fileName(op.deviceId, op.seq));
            }
          } else if (!_holds(op.deviceId, op.seq)) {
            fresh.add(op);
          }
        }
        if (fresh.isNotEmpty) {
          await _store.appendOps(fresh);
          for (final op in fresh) {
            _keys.add(op.key);
            _log.add(op);
            _state.applyOp(op);
            if (op.deviceId == deviceId) _nextSeq = max(_nextSeq, op.seq + 1);
          }
        }
        final high = _state.maxStamp;
        if (high != null && high != before) {
          _clock = _clock.receive(high, _physicalMillis());
        }
        // Make joined knowledge durable, and shed the pulled ops it covers.
        if (joined > 0) await _saveLocal();
        return fresh.length + joined;
      });

  // --- snapshots ---

  bool _holds(String author, int seq) =>
      seq < (_base[author] ?? 0) || _keys.contains('$author#$seq');

  void _raiseBase(Map<String, int> cut) {
    cut.forEach((author, n) {
      if (n > (_base[author] ?? 0)) _base[author] = n;
    });
  }

  /// Reserve the next gen, persist the state under it, and queue the upload.
  Future<void> _publishSnapshot() async {
    _gen++;
    final bytes = await _saveLocal();
    _pendingSnapshot = (
      name: SnapshotFormat.fileName(deviceId, _gen),
      bytes: bytes,
      gen: _gen,
    );
    _joinedGen[deviceId] = _gen;
  }

  /// Save the whole state as the local snapshot at the current [frontier],
  /// then drop the pulled ops it covers from the store and the log. Own ops
  /// stay: they are re-pushed until confirmed. Returns the snapshot bytes.
  /// Call inside [_exclusive].
  Future<Uint8List> _saveLocal() async {
    final cut = frontier;
    _state.prune();
    final bytes =
        Snapshot(writer: deviceId, gen: _gen, cut: cut, state: _state).encode();
    await _store.saveSnapshot(bytes);
    _raiseBase(cut);
    final covered = <Op>[
      for (final op in _log)
        if (op.deviceId != deviceId && op.seq < (_base[op.deviceId] ?? 0)) op,
    ];
    if (covered.isNotEmpty) {
      await _store.removeOps(covered);
      final gone = <String>{for (final op in covered) op.key};
      _log.removeWhere((op) => gone.contains(op.key));
      _keys.removeAll(gone);
    }
    return bytes;
  }

  // --- open ---

  void _load(Uint8List? snapshot, List<Op> stored) {
    if (snapshot != null) {
      // An honest store never returns a corrupt snapshot: a decode failure is
      // surfaced, not papered over.
      final s = Snapshot.decode(snapshot);
      if (s.writer != deviceId) {
        throw StateError('local snapshot belongs to ${s.writer}, not '
            '$deviceId');
      }
      _state.join(s.state);
      _raiseBase(s.cut);
      _gen = s.gen;
      _joinedGen[deviceId] = s.gen;
      _nextSeq = _base[deviceId] ?? 0;
    }
    for (final op in stored) {
      if (_keys.contains(op.key)) continue;
      // Covered pulled ops whose removal a crash interrupted: already folded.
      if (op.deviceId != deviceId && _holds(op.deviceId, op.seq)) continue;
      _keys.add(op.key);
      _log.add(op);
      _state.applyOp(op);
      if (op.deviceId == deviceId) {
        _nextSeq = max(_nextSeq, op.seq + 1);
        _unconfirmed[OpFileFormat.fileName(deviceId, op.seq)] = op;
      }
    }
    // Clock at the highest stamp held, so the next tick orders after every op
    // this device has authored or seen — the clock need not be stored.
    final high = _state.maxStamp;
    if (high != null) _clock = Hlc(high.wallMillis, high.counter, deviceId);
  }

  static String _newDeviceId(Random rng) => <String>[
        for (var i = 0; i < 16; i++)
          rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ].join();

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
