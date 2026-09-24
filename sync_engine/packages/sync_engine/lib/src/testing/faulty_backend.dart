import 'dart:math';
import 'dart:typed_data';

import '../backend.dart';

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
    this.droppedDelete = 0,
    this.staleDepth = 3,
    this.visibilityDelay = 2,
  });

  /// Persist a prefix of the bytes, then surface a failure.
  double truncatedUpload;

  /// Return the listing from [staleDepth] `list()` calls ago.
  double staleList;

  /// Hide a freshly uploaded file from `list()` for [visibilityDelay] steps.
  double delayedVisibility;

  /// Report upload success while persisting nothing.
  double droppedUpload;

  /// List the same file twice.
  double duplicateDelivery;

  /// Report a delete as done while the file stays.
  double droppedDelete;

  /// N: how far back a stale listing is drawn from.
  int staleDepth;

  /// K: steps a delayed file stays invisible.
  int visibilityDelay;

  /// A perfectly honest backend.
  static FaultConfig none() => FaultConfig();
}

/// Wraps any [Backend] and makes it exhibit the lies the contract allows: the
/// five upload/listing faults, plus deletes that silently do nothing.
/// Deterministic: every fault decision is drawn from the injected [Random], so
/// a seed replays the same fault schedule over any inner backend.
///
/// Faults are layered ON TOP of [inner], so a real backend sees real partial
/// writes (a truncated prefix is really uploaded) and the client sees real
/// stale or duplicated listings of what [inner] actually holds.
class FaultyBackend implements Backend {
  FaultyBackend(this.inner, this._rng, {FaultConfig? faults})
      : faults = faults ?? FaultConfig();

  final Backend inner;
  final Random _rng;
  FaultConfig faults;

  /// name -> steps remaining until the file becomes visible to `list()`.
  final Map<String, int> _hiddenFor = <String, int>{};

  /// Recent true listings, newest last. Bounded; only the tail is kept.
  final List<List<RemoteFile>> _snapshots = <List<RemoteFile>>[];
  static const int _snapshotWindow = 8;

  bool _dice(double p) => p > 0 && _rng.nextDouble() < p;

  /// Advance the fault clock: decay visibility timers.
  void _tick() {
    _hiddenFor.updateAll((_, v) => v > 0 ? v - 1 : 0);
    _hiddenFor.removeWhere((_, v) => v == 0);
  }

  @override
  Future<List<RemoteFile>> list() async {
    _tick();
    final visible = <RemoteFile>[
      for (final f in await inner.list())
        if (!_hiddenFor.containsKey(f.name)) f,
    ];
    _snapshots.add(visible);
    if (_snapshots.length > _snapshotWindow) _snapshots.removeAt(0);

    var base = visible;
    if (_dice(faults.staleList) && _snapshots.length > faults.staleDepth) {
      base = _snapshots[_snapshots.length - 1 - faults.staleDepth];
    }
    final result = List<RemoteFile>.of(base);
    if (_dice(faults.duplicateDelivery) && result.isNotEmpty) {
      result.add(result[_rng.nextInt(result.length)]);
    }
    return result;
  }

  @override
  Future<Uint8List> download(String name) => inner.download(name);

  @override
  Future<void> upload(String name, Uint8List bytes) async {
    _tick();
    if (_dice(faults.droppedUpload)) {
      return; // Report success, persist nothing.
    }
    if (_dice(faults.truncatedUpload) && bytes.length > 1) {
      final cut = 1 + _rng.nextInt(bytes.length - 1);
      await inner.upload(name, Uint8List.fromList(bytes.sublist(0, cut)));
      _armVisibility(name);
      throw StateError('upload truncated: $name');
    }
    await inner.upload(name, bytes);
    _armVisibility(name);
  }

  void _armVisibility(String name) {
    if (_dice(faults.delayedVisibility)) {
      _hiddenFor[name] = faults.visibilityDelay;
    } else {
      _hiddenFor.remove(name);
    }
  }

  @override
  Future<void> delete(String name) async {
    _tick();
    if (_dice(faults.droppedDelete)) return; // report success, keep the file
    await inner.delete(name);
    _hiddenFor.remove(name);
  }
}
