import 'dart:math';
import 'dart:typed_data';

import '../backend.dart';
import '../crdt_engine.dart';
import '../hlc.dart';
import '../local_store.dart';
import '../op.dart';
import '../operation.dart';
import '../operation_codec.dart';
import '../sync_client.dart';
import 'faulty_backend.dart';
import 'memory_backend.dart';

/// One simulated device: a durable [store] and the [client] currently open on
/// it. A crash discards the client and reopens a new one from the store, so
/// restart recovery is the real `SyncClient.open` path, not a simulation.
class FuzzDevice {
  FuzzDevice._(this.id, this.store);

  final String id;
  final MemoryStore store;
  late SyncClient client;

  /// Physical-clock offset the clock-skew action nudges.
  int clockSkewMs = 0;

  List<Op> get log => client.ops;
  int get logLength => client.ops.length;

  // Causality oracle state: highest stamp in the first [_scanned] log entries.
  int _scanned = 0;
  Hlc? _maxHeld;
}

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
  final List<FuzzDevice> devices;
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
///
/// Devices sync through [backend] (default: a fresh [MemoryBackend]) wrapped
/// in a [FaultyBackend]. Pass a real backend over EMPTY storage to put it
/// through the same fault fuzzer; it must be deterministic in listing order
/// for a seed to replay exactly.
Future<FuzzResult> runFuzz(
  int seed, {
  FuzzConfig? config,
  Backend? backend,
}) async {
  final cfg = config ?? FuzzConfig();
  final rng = Random(seed);
  final faulty =
      FaultyBackend(backend ?? MemoryBackend(), rng, faults: cfg.faults());

  final deviceCount = 2 + rng.nextInt(7); // 2..8
  final devices = <FuzzDevice>[
    for (var i = 0; i < deviceCount; i++) FuzzDevice._('d$i', MemoryStore()),
  ];

  // Deterministic physical clock: a monotonic base tick plus each device's own
  // skew. Never wall-clock, so a seed reproduces every HLC exactly.
  var physicalTick = 0;
  Future<void> open(FuzzDevice dev) async {
    dev
      ..client = await SyncClient.open(
        backend: faulty,
        store: dev.store,
        deviceId: dev.id,
        physicalMillis: () => physicalTick + dev.clockSkewMs,
      )
      .._scanned = 0
      .._maxHeld = null;
  }

  FuzzResult fail(String reason, int drainRounds) => FuzzResult(
        seed: seed,
        converged: false,
        devices: devices,
        drainRounds: drainRounds,
        failureReason: reason,
      );

  try {
    for (final dev in devices) {
      await open(dev);
    }

    // --- chaos phase ---
    for (var step = 0; step < cfg.steps; step++) {
      physicalTick += 1;
      final dev = devices[rng.nextInt(devices.length)];
      final client = dev.client;
      final roll = rng.nextInt(100);
      if (roll < 55) {
        // Local op over a small doc/field/element space, so devices contend
        // and merge order matters.
        _scan(dev);
        final docId = 'doc${rng.nextInt(3)}';
        switch (rng.nextInt(5)) {
          case 0:
            await client.put(docId, 'f${rng.nextInt(5)}', _randomPayload(rng));
          case 1:
            await client.addToSet(docId, 'tags', _element(rng));
          case 2:
            await client.removeFromSet(docId, 'tags', _element(rng));
          case 3:
            // RGA insert at head or after a random existing element.
            final ids = CrdtEngine.elementIds(client.ops, docId, 'items');
            final after = ids.isEmpty || rng.nextBool()
                ? null
                : ids[rng.nextInt(ids.length)];
            await client.insertIntoList(docId, 'items', _randomPayload(rng),
                after: after);
          default:
            // RGA delete of a random existing element, else insert instead.
            final ids = CrdtEngine.elementIds(client.ops, docId, 'items');
            if (ids.isEmpty) {
              await client.insertIntoList(docId, 'items', _randomPayload(rng));
            } else {
              await client.removeFromList(
                  docId, 'items', ids[rng.nextInt(ids.length)]);
            }
        }
        final violation = _checkCausality(dev);
        if (violation != null) return fail(violation, 0);
      } else if (roll < 85) {
        await client.sync(); // real merge round
      } else if (roll < 95) {
        await open(dev); // crash: drop the client, reopen from the store
      } else {
        dev.clockSkewMs += rng.nextInt(2001) - 1000; // +/- 1s skew
      }
    }

    // --- drain phase: sync rounds until quiescent ---
    if (!cfg.faultsDuringDrain) {
      faulty.faults = FaultConfig.none();
    }
    var quiescent = false;
    var rounds = 0;
    for (; rounds < cfg.maxDrainRounds; rounds++) {
      final before = _totalLog(devices);
      // Two passes, so a file the last device pushes reaches the first.
      for (var pass = 0; pass < 2; pass++) {
        for (final d in devices) {
          await d.client.sync();
        }
      }
      final pending = devices.fold(0, (n, d) => n + d.client.pendingUploads);
      if (_totalLog(devices) == before && pending == 0) {
        quiescent = true;
        rounds++;
        break;
      }
    }

    // --- convergence assertion ---
    if (!quiescent) {
      return fail(
          'not quiescent after ${cfg.maxDrainRounds} drain rounds', rounds);
    }
    final reference = devices.first.client.materialize();
    for (final d in devices.skip(1)) {
      final state = d.client.materialize();
      if (!_bytesEqual(reference, state)) {
        return fail(
            'device ${d.id} merged state diverged from ${devices.first.id}: '
            '${state.length} bytes vs ${reference.length}',
            rounds);
      }
    }

    // Secondary invariant: identical op-log SETS (transport completeness).
    final refKeys = _opKeys(devices.first);
    for (final d in devices.skip(1)) {
      if (!_listEqualString(refKeys, _opKeys(d))) {
        return fail(
            'device ${d.id} op-log set differs from ${devices.first.id}',
            rounds);
      }
    }

    return FuzzResult(
      seed: seed,
      converged: true,
      devices: devices,
      drainRounds: rounds,
    );
  } on Object catch (e) {
    // Nothing in a fuzz run may throw: the backend's lies are all allowed.
    return fail('threw: $e', 0);
  }
}

/// Fold the not-yet-scanned tail of [dev]'s log into its highest held stamp.
void _scan(FuzzDevice dev) {
  final log = dev.client.ops;
  for (; dev._scanned < log.length; dev._scanned++) {
    for (final s in _stampsOf(log[dev._scanned])) {
      final m = dev._maxHeld;
      if (m == null || s.compareTo(m) > 0) dev._maxHeld = s;
    }
  }
}

/// Causality: a stamp minted by a local op must order after every stamp the
/// device held when it authored it, whatever the wall-clock skew. Otherwise a
/// later edit can lose to the edit it replaced.
String? _checkCausality(FuzzDevice dev) {
  final log = dev.client.ops;
  final held = dev._maxHeld;
  for (var i = dev._scanned; i < log.length; i++) {
    final minted = _mintedStamp(log[i]);
    if (minted != null && held != null && minted.compareTo(held) <= 0) {
      return 'causality: device ${dev.id} minted $minted, not after held '
          'stamp $held';
    }
  }
  _scan(dev);
  return null;
}

/// The fresh stamp an op mints, if its type mints one.
Hlc? _mintedStamp(Op op) => switch (_decode(op)) {
      MapPut(:final hlc) => hlc,
      SetAdd(:final tag) => tag,
      ListInsert(:final id) => id,
      _ => null,
    };

/// Every stamp an op carries, minted or referenced.
List<Hlc> _stampsOf(Op op) => switch (_decode(op)) {
      MapPut(:final hlc) => <Hlc>[hlc],
      SetAdd(:final tag) => <Hlc>[tag],
      SetRemove(:final observedTags) => observedTags,
      ListInsert(:final id, :final after) => <Hlc>[
          id,
          if (after != null) after
        ],
      ListDelete(:final elementId) => <Hlc>[elementId],
      null => const <Hlc>[],
    };

Operation? _decode(Op op) {
  try {
    return OperationCodec.decode(op.payload);
  } on FormatException {
    return null;
  }
}

Uint8List _randomPayload(Random rng) {
  final len = 4 + rng.nextInt(13); // 4..16 bytes
  return Uint8List.fromList(
      <int>[for (var i = 0; i < len; i++) rng.nextInt(256)]);
}

/// One of a small set of OR-set elements, so adds and removes collide.
Uint8List _element(Random rng) =>
    Uint8List.fromList('t${rng.nextInt(5)}'.codeUnits);

int _totalLog(List<FuzzDevice> devices) =>
    devices.fold(0, (n, d) => n + d.logLength);

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<String> _opKeys(FuzzDevice d) =>
    d.log.map((op) => op.key).toList()..sort();

bool _listEqualString(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
