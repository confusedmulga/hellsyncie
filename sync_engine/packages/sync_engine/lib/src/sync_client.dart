import 'dart:math';
import 'dart:typed_data';

import 'backend.dart';
import 'crdt_engine.dart';
import 'engine.dart';
import 'format.dart';
import 'hlc.dart';
import 'local_store.dart';
import 'op.dart';
import 'op_codec.dart';
import 'operation.dart';
import 'operation_codec.dart';

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

  /// Ops ingested from the backend this round. Non-zero means the
  /// materialized state may have changed.
  final int received;

  /// This device's ops not yet confirmed intact on the backend. They are
  /// re-uploaded every round until a readback matches.
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
    this._engine,
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
    SyncEngine engine = const CrdtEngine(),
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
      engine,
      physicalMillis ?? () => DateTime.now().millisecondsSinceEpoch,
    ).._load(await store.loadOps());
    return client;
  }

  /// This device's id. Every op file it writes carries it.
  final String deviceId;

  final Backend _backend;
  final LocalStore _store;
  final SyncEngine _engine;
  final int Function() _physicalMillis;

  Hlc _clock;
  int _nextSeq = 0;
  final List<Op> _log = <Op>[];
  final Set<String> _keys = <String>{}; // op keys already in _log

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

  /// Every op this device holds, own and pulled, in local arrival order.
  List<Op> get ops => List<Op>.unmodifiable(_log);

  /// The device's hybrid logical clock: at or above every stamp it holds.
  Hlc get clock => _clock;

  /// Own ops not yet confirmed on the backend.
  int get pendingUploads => _unconfirmed.length;

  /// The merged state: a pure fold over every op held. Byte-identical on
  /// every device holding the same op set.
  Uint8List materialize() => _engine.materialize(_log);

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
        final observed = CrdtEngine.addTagsFor(_log, docId, setField, element);
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

  Future<SyncResult> _round() async {
    var received = 0;
    if (!_pulledSinceOpen) received += await _pull();
    await _push();
    received += await _pull();
    return SyncResult(received: received, pending: _unconfirmed.length);
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
  }

  /// List; confirm own uploads by readback; download unseen op files; ingest.
  Future<int> _pull() async {
    final listing = await _backend.list();
    final fetched = <Op>[];
    for (final name in <String>{for (final f in listing) f.name}) {
      final id = OpFileFormat.parseFileName(name);
      if (id == null) continue; // not an op file
      final mine = _unconfirmed[name];
      if (mine != null) {
        await _confirm(name, mine);
      } else if (!_keys.contains('${id.deviceId}#${id.seq}')) {
        // Another device's op — or our own that this store lost; re-adopting
        // it moves our sequence counter past it so the number is never reused.
        final op = await _fetch(name, '${id.deviceId}#${id.seq}');
        if (op != null) fetched.add(op);
      }
    }
    final received = await _ingest(fetched);
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

  Future<int> _ingest(List<Op> fetched) => _exclusive(() async {
        final fresh = <Op>[];
        for (final op in fetched) {
          if (!_keys.contains(op.key)) {
            fresh.add(op);
          } else if (op.deviceId == deviceId) {
            // Authored locally while this pull ran, yet a different op already
            // sits under that identity on the backend.
            final own = _log.firstWhere((o) => o.key == op.key);
            if (!_bytesEqual(own.payload, op.payload)) {
              throw DeviceIdCollisionException(
                  deviceId, OpFileFormat.fileName(op.deviceId, op.seq));
            }
          }
        }
        if (fresh.isEmpty) return 0;
        await _store.appendOps(fresh);
        Hlc? high;
        for (final op in fresh) {
          _keys.add(op.key);
          _log.add(op);
          if (op.deviceId == deviceId) _nextSeq = max(_nextSeq, op.seq + 1);
          high = _maxStamp(high, op);
        }
        if (high != null) _clock = _clock.receive(high, _physicalMillis());
        return fresh.length;
      });

  // --- open ---

  void _load(List<Op> stored) {
    Hlc? high;
    for (final op in stored) {
      if (!_keys.add(op.key)) continue;
      _log.add(op);
      if (op.deviceId == deviceId) {
        _nextSeq = max(_nextSeq, op.seq + 1);
        _unconfirmed[OpFileFormat.fileName(deviceId, op.seq)] = op;
      }
      high = _maxStamp(high, op);
    }
    // Clock at the highest stamp held, so the next tick orders after every op
    // this device has authored or seen — the clock need not be stored.
    if (high != null) _clock = Hlc(high.wallMillis, high.counter, deviceId);
  }

  static Hlc? _maxStamp(Hlc? high, Op op) {
    for (final s in _stampsOf(op)) {
      if (high == null || s.compareTo(high) > 0) high = s;
    }
    return high;
  }

  /// Every HLC an op carries, authored or referenced.
  static List<Hlc> _stampsOf(Op op) {
    final Operation o;
    try {
      o = OperationCodec.decode(op.payload);
    } on FormatException {
      return const <Hlc>[];
    }
    return switch (o) {
      MapPut(:final hlc) => <Hlc>[hlc],
      SetAdd(:final tag) => <Hlc>[tag],
      SetRemove(:final observedTags) => observedTags,
      ListInsert(:final id, :final after) => <Hlc>[
          id,
          if (after != null) after
        ],
      ListDelete(:final elementId) => <Hlc>[elementId],
    };
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
