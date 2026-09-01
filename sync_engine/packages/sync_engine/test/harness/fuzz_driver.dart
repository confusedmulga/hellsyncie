import 'dart:math';
import 'dart:typed_data';

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

  // --- chaos phase ---
  for (var step = 0; step < cfg.steps; step++) {
    final dev = devices[rng.nextInt(devices.length)];
    final roll = rng.nextInt(100);
    if (roll < 55) {
      dev.applyLocalOp(_randomPayload(rng));
    } else if (roll < 85) {
      // Sync attempt. Prove the engine seam exists and then fall back to the
      // transport-only exchange until the engine is implemented.
      try {
        await dev.sync(backend);
      } on UnimplementedError {
        await dev.push(backend);
        await dev.pull(backend);
      }
    } else if (roll < 95) {
      dev.crashRestart();
    } else {
      dev.clockSkewMs += rng.nextInt(2001) - 1000; // +/- 1s, placeholder
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
      reason = 'device ${devices[i].id} diverged from ${devices.first.id}: '
          '${states[i].length} state bytes vs ${reference.length}';
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
