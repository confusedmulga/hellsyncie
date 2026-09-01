import 'dart:math';
import 'dart:typed_data';

import 'package:sync_engine/sync_engine.dart';

/// Fault probabilities, each independently controllable in `[0.0 .. 1.0]`.
/// All faults are driven from the fuzz run's single seeded RNG, so a seed
/// reproduces the exact fault schedule.
class FaultConfig {
  FaultConfig({
    this.truncatedUpload = 0,
    this.staleList = 0,
    this.delayedVisibility = 0,
    this.droppedUpload = 0,
    this.duplicateDelivery = 0,
    this.staleDepth = 3,
    this.visibilityDelay = 2,
  });

  /// Persist a prefix of the bytes, then surface a failure.
  double truncatedUpload;

  /// Return a `list()` snapshot from [staleDepth] operations ago.
  double staleList;

  /// Hide a freshly uploaded file from `list()` for [visibilityDelay] steps.
  double delayedVisibility;

  /// Report upload success while persisting nothing.
  double droppedUpload;

  /// List the same file twice.
  double duplicateDelivery;

  /// N: how far back a stale listing is drawn from.
  int staleDepth;

  /// K: steps a delayed file stays invisible.
  int visibilityDelay;

  /// A perfectly honest backend.
  static FaultConfig none() => FaultConfig();
}

/// In-memory [Backend] that injects the exact failure modes real dumb storage
/// exhibits. Deterministic: every fault decision is drawn from the injected
/// [Random], so a seed replays byte-for-byte.
class SimulatedBackend implements Backend {
  SimulatedBackend(this._rng, {FaultConfig? faults})
      : faults = faults ?? FaultConfig();

  final Random _rng;
  FaultConfig faults;

  final Map<String, Uint8List> _store = <String, Uint8List>{};

  /// name -> steps remaining until the file becomes visible to `list()`.
  final Map<String, int> _hiddenFor = <String, int>{};

  /// Recent listing snapshots, newest last. Bounded; only the tail is kept.
  final List<List<RemoteFile>> _snapshots = <List<RemoteFile>>[];
  static const int _snapshotWindow = 8;

  int get fileCount => _store.length;

  bool _dice(double p) => p > 0 && _rng.nextDouble() < p;

  /// Advance the backend clock: decay visibility timers, record a snapshot.
  void _tick() {
    _hiddenFor.updateAll((_, v) => v > 0 ? v - 1 : 0);
    _snapshots.add(_visibleNow());
    if (_snapshots.length > _snapshotWindow) {
      _snapshots.removeAt(0);
    }
  }

  List<RemoteFile> _visibleNow() {
    final out = <RemoteFile>[];
    _store.forEach((name, bytes) {
      if ((_hiddenFor[name] ?? 0) > 0) return;
      out.add(RemoteFile(name, bytes.length));
    });
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  @override
  Future<List<RemoteFile>> list() async {
    _tick();
    List<RemoteFile> base;
    if (_dice(faults.staleList) && _snapshots.length > faults.staleDepth) {
      base = _snapshots[_snapshots.length - 1 - faults.staleDepth];
    } else {
      base = _visibleNow();
    }
    final result = List<RemoteFile>.of(base);
    if (_dice(faults.duplicateDelivery) && result.isNotEmpty) {
      result.add(result[_rng.nextInt(result.length)]);
    }
    return result;
  }

  @override
  Future<Uint8List> download(String name) async {
    final bytes = _store[name];
    if (bytes == null) {
      throw StateError('download: no such file: $name');
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> upload(String name, Uint8List bytes) async {
    _tick();
    if (_dice(faults.droppedUpload)) {
      // Report success, persist nothing.
      return;
    }
    if (_dice(faults.truncatedUpload) && bytes.length > 1) {
      final cut = 1 + _rng.nextInt(bytes.length - 1);
      _store[name] = Uint8List.fromList(bytes.sublist(0, cut));
      _armVisibility(name);
      throw StateError('upload truncated: $name');
    }
    _store[name] = Uint8List.fromList(bytes);
    _armVisibility(name);
  }

  void _armVisibility(String name) {
    _hiddenFor[name] =
        _dice(faults.delayedVisibility) ? faults.visibilityDelay : 0;
  }

  @override
  Future<void> delete(String name) async {
    _tick();
    _store.remove(name);
    _hiddenFor.remove(name);
  }
}
