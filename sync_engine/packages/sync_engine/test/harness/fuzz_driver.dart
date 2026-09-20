import 'dart:math';
import 'dart:typed_data';

import 'package:sync_engine/sync_engine.dart';

import 'simulated_backend.dart';
import 'simulated_device.dart';

/// Outcome of a single seeded fuzz run.
class FuzzResult {
  FuzzResult({
    required this.seed,
    required this.converged,
    required this.devices,
    required this.drainRounds,
    this.failureReason,
  });

  final int seed;
  final bool converged;
  final List<SimulatedDevice> devices;
  final int drainRounds;
  final String? failureReason;
}

/// Knobs for a run. Everything else derives from the seed.
class FuzzConfig {
  FuzzConfig({
    this.steps = 200,
    FaultConfig Function()? faults,
    this.faultsDuringDrain = false,
    this.maxDrainRounds = 64,
  }) : faults = faults ?? defaultFaults;

  /// Number of chaos steps before the final drain.
  final int steps;

  /// Builds the fault schedule. Must NOT draw from the run RNG (keeps the draw
  /// order stable across configs).
  final FaultConfig Function() faults;

  /// Keep faults active during the final drain. Used to demonstrate the
  /// failure path; a permanent fault prevents convergence on purpose.
  final bool faultsDuringDrain;

  /// Cap on drain rounds before declaring "not quiescent".
  final int maxDrainRounds;

  static FaultConfig defaultFaults() => FaultConfig(
        truncatedUpload: 0.10,
        staleList: 0.20,
        delayedVisibility: 0.20,
        droppedUpload: 0.10,
        duplicateDelivery: 0.15,
      );
}

/// Run one fully deterministic fuzz iteration. The single [seed] fixes device
/// count, op sequence, sync ordering, and the entire fault schedule.
Future<FuzzResult> runFuzz(int seed, {FuzzConfig? config}) async {
  final cfg = config ?? FuzzConfig();
  final rng = Random(seed);
  final backend = SimulatedBackend(rng, faults: cfg.faults());

  final deviceCount = 2 + rng.nextInt(7); // 2..8
  final devices = <SimulatedDevice>[
    for (var i = 0; i < deviceCount; i++) SimulatedDevice('d$i'),
  ];

  // Deterministic physical clock: a monotonic base tick plus each device's own
  // skew. Never wall-clock, so a seed reproduces every HLC exactly.
  var physicalTick = 0;
  for (final dev in devices) {
    dev.physicalMillis = () => physicalTick + dev.clockSkewMs;
  }

  // --- chaos phase ---
  for (var step = 0; step < cfg.steps; step++) {
    physicalTick += 1;
    final dev = devices[rng.nextInt(devices.length)];
    final roll = rng.nextInt(100);
    if (roll < 55) {
      // Local op over a small doc/field/element space, so devices contend and
      // merge order matters: LWW put, OR-set add, or OR-set remove.
      final docId = 'doc${rng.nextInt(3)}';
      switch (rng.nextInt(5)) {
        case 0:
          dev.applyPut(docId, 'f${rng.nextInt(5)}', _randomPayload(rng));
        case 1:
          dev.applyAdd(docId, 'tags', _element(rng));
        case 2:
          dev.applyRemove(docId, 'tags', _element(rng));
        case 3:
          // RGA insert at head or after a random existing element.
          final ids = CrdtEngine.elementIds(dev.log, docId, 'items');
          final after = ids.isEmpty || rng.nextBool()
              ? null
              : ids[rng.nextInt(ids.length)];
          dev.applyInsert(docId, 'items', _randomPayload(rng), after: after);
        default:
          // RGA delete of a random existing element, else insert instead.
          final ids = CrdtEngine.elementIds(dev.log, docId, 'items');
          if (ids.isEmpty) {
            dev.applyInsert(docId, 'items', _randomPayload(rng));
          } else {
            dev.applyRemoveListItem(
                docId, 'items', ids[rng.nextInt(ids.length)]);
          }
      }
    } else if (roll < 85) {
      await dev.sync(backend); // real merge round
    } else if (roll < 95) {
      dev.crashRestart();
    } else {
      dev.clockSkewMs += rng.nextInt(2001) - 1000; // +/- 1s skew
    }
  }

  // --- drain phase: force sync rounds until quiescent ---
  if (!cfg.faultsDuringDrain) {
    backend.faults = FaultConfig.none();
  }
  var quiescent = false;
  var rounds = 0;
  for (; rounds < cfg.maxDrainRounds; rounds++) {
    final before = _totalLog(devices);
    for (final d in devices) {
      await d.push(backend);
    }
    for (final d in devices) {
      await d.pull(backend);
    }
    // Second pass so a file uploaded this round reaches everyone this round.
    for (final d in devices) {
      await d.push(backend);
    }
    for (final d in devices) {
      await d.pull(backend);
    }
    if (_totalLog(devices) == before) {
      quiescent = true;
      rounds++;
      break;
    }
  }

  // --- convergence assertion ---
  final states = <Uint8List>[for (final d in devices) d.materializedState()];
  final reference = states.first;
  var converged = quiescent;
  String? reason = quiescent
      ? null
      : 'not quiescent after ${cfg.maxDrainRounds} drain rounds';

  for (var i = 1; i < states.length && converged; i++) {
    if (!_bytesEqual(reference, states[i])) {
      converged = false;
      reason = 'device ${devices[i].id} merged state diverged from '
          '${devices.first.id}: ${states[i].length} bytes vs '
          '${reference.length}';
    }
  }

  // Secondary invariant: identical op-log SETS (transport completeness).
  if (converged) {
    final refKeys = _opKeys(devices.first);
    for (var i = 1; i < devices.length; i++) {
      if (!_listEqualString(refKeys, _opKeys(devices[i]))) {
        converged = false;
        reason = 'device ${devices[i].id} op-log set differs from '
            '${devices.first.id}';
        break;
      }
    }
  }

  return FuzzResult(
    seed: seed,
    converged: converged,
    devices: devices,
    drainRounds: rounds,
    failureReason: reason,
  );
}

Uint8List _randomPayload(Random rng) {
  final len = 4 + rng.nextInt(13); // 4..16 bytes
  return Uint8List.fromList(
      <int>[for (var i = 0; i < len; i++) rng.nextInt(256)]);
}

/// One of a small set of OR-set elements, so adds and removes collide.
Uint8List _element(Random rng) =>
    Uint8List.fromList('t${rng.nextInt(5)}'.codeUnits);

int _totalLog(List<SimulatedDevice> devices) {
  var n = 0;
  for (final d in devices) {
    n += d.logLength;
  }
  return n;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<String> _opKeys(SimulatedDevice d) =>
    d.log.map((op) => op.key).toList()..sort();

bool _listEqualString(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
