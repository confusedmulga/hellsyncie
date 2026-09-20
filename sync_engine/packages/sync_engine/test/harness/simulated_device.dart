import 'dart:typed_data';

import 'package:sync_engine/sync_engine.dart';

/// A device in the simulation: a stable id, a durable append-only op log, a
/// hybrid logical clock, a buffer of authored op files not yet confirmed on the
/// backend, and a real [sync] round backed by the CRDT engine.
///
/// The device NEVER trusts an upload's success return — a file counts as
/// persisted only once a real `list()` shows it. That is what defeats dropped
/// and truncated uploads: unconfirmed files are re-pushed (idempotently, since
/// op files are immutable and named by identity).
class SimulatedDevice {
  SimulatedDevice(this.id, {SyncEngine? engine})
      : _engine = engine ?? const CrdtEngine(),
        _clock = Hlc.zero(id);

  final String id;
  final SyncEngine _engine;

  /// Physical clock source (millis since epoch). Injected so the fuzzer stays
  /// deterministic; production passes wall-clock time.
  int Function() physicalMillis = () => DateTime.now().millisecondsSinceEpoch;

  /// This device's hybrid logical clock, advanced on each local op. Durable —
  /// survives [crashRestart] alongside the log.
  Hlc _clock;

  final List<Op> _log = <Op>[];
  final Set<String> _keys = <String>{}; // op keys already in _log
  int _seq = 0;

  /// Bytes of every op this device authored, by file name (durable; survives a
  /// crash and is re-pushed on restart).
  final Map<String, Uint8List> _authored = <String, Uint8List>{};

  /// Authored file names not yet confirmed present in a backend listing.
  final Set<String> _unconfirmed = <String>{};

  /// File names already ingested, so pulls stay idempotent under duplicate
  /// delivery. Transient — rebuilt from the durable log on restart.
  final Set<String> _seenFiles = <String>{};

  /// Physical-clock offset the clock-skew fuzz action nudges. The injected
  /// [physicalMillis] adds it in, so skew flows into real HLC behavior.
  int clockSkewMs = 0;

  int get logLength => _log.length;
  List<Op> get log => List<Op>.unmodifiable(_log);

  /// Author a local field write (LWW-register map put). Advances the HLC,
  /// encodes the operation, and mints an op file for it.
  void applyPut(String docId, String field, Uint8List value) {
    _clock = _clock.send(physicalMillis());
    final op = MapPut(docId: docId, field: field, value: value, hlc: _clock);
    _mint(OperationCodec.encode(op));
  }

  void _mint(Uint8List payload) {
    final op = Op(id, _seq++, payload);
    _add(op);
    final name = OpFileFormat.fileName(id, op.seq);
    _authored[name] = OpCodec.encode(op);
    _unconfirmed.add(name);
    _seenFiles.add(name); // we already hold our own op
  }

  bool _add(Op op) {
    if (_keys.add(op.key)) {
      _log.add(op);
      return true;
    }
    return false;
  }

  /// One sync round: push local ops, then pull remote ops. The merge itself is
  /// the pure fold in [materializedState] over the resulting op set.
  Future<void> sync(Backend backend) async {
    await push(backend);
    await pull(backend);
  }

  /// Upload every unconfirmed authored file. Idempotent; safe to repeat.
  Future<void> push(Backend backend) async {
    for (final name in _unconfirmed.toList()) {
      try {
        await backend.upload(name, _authored[name]!);
      } on Object {
        // Truncated/failed upload: stays unconfirmed, retried next push.
      }
    }
  }

  /// List, confirm our own now-visible files, download unseen files, decode
  /// them (skipping corrupt/truncated), and add new ops to the log.
  Future<void> pull(Backend backend) async {
    final listing = await backend.list();
    final names = <String>{for (final f in listing) f.name};

    // Confirm our own uploads ONLY if the stored copy reads back INTACT. A
    // truncated upload leaves a corrupt file under the right name; trusting the
    // name alone would strand the full copy and diverge the devices. Verify by
    // download + decode; anything corrupt stays queued and is re-pushed.
    for (final name in _unconfirmed.toList()) {
      if (!names.contains(name)) continue;
      try {
        OpCodec.decode(await backend.download(name));
        _unconfirmed.remove(name);
      } on Object {
        // corrupt / truncated / not-really-there: keep queued for re-push
      }
    }

    for (final name in names) {
      if (_seenFiles.contains(name)) continue;
      Uint8List bytes;
      try {
        bytes = await backend.download(name);
      } on Object {
        continue; // not really readable yet; retry later
      }
      final Op op;
      try {
        op = OpCodec.decode(bytes);
      } on FormatException {
        continue; // corrupt/truncated: skip, do NOT mark seen, re-fetch later
      }
      _seenFiles.add(name);
      _add(op);
    }
  }

  /// Simulate a crash + restart. Transient state (confirmation status, seen
  /// set) is lost; the durable op log and authored bytes survive. All authored
  /// files are re-queued for confirmation and re-pushed idempotently.
  void crashRestart() {
    _unconfirmed
      ..clear()
      ..addAll(_authored.keys);
    _seenFiles
      ..clear()
      ..addAll(_authored.keys);
    for (final op in _log) {
      _seenFiles.add(OpFileFormat.fileName(op.deviceId, op.seq));
    }
  }

  /// The converged materialized state: the CRDT engine's pure fold over every
  /// op this device holds. Byte-identical across devices with the same op set.
  Uint8List materializedState() => _engine.materialize(_log);
}
