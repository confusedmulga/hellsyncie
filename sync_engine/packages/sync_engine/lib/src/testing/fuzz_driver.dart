import 'dart:math';
import 'dart:typed_data';

import '../backend.dart';
import '../format.dart';
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

  /// Ops held individually (the client's log; compaction shrinks it).
  List<Op> get log => client.ops;
  int get logLength => client.ops.length;

  /// Everything this device holds, canonically: `author<count` for each
  /// contiguous run from seq 0 (in a snapshot or the log), then every key held
  /// beyond it. Equal coverage = the same op set, however it is stored.
  List<String> get coverage => _coverage(client);

  int get coverageSize {
    final frontier = client.frontier;
    return frontier.values.fold(0, (n, v) => n + v) +
        client.ops.where((op) => op.seq >= (frontier[op.deviceId] ?? 0)).length;
  }
}

List<String> _coverage(SyncClient client) {
  final frontier = client.frontier;
  return <String>[
    for (final MapEntry(key: a, value: n) in frontier.entries) '$a<$n',
    for (final op in client.ops)
      if (op.seq >= (frontier[op.deviceId] ?? 0)) op.key,
  ]..sort();
}

/// Outcome of a single seeded fuzz run.
class FuzzResult {
  FuzzResult({
    required this.seed,
    required this.converged,
    required this.devices,
    required this.drainRounds,
    this.failureReason,
    this.compactions = 0,
    this.snapshotFiles = 0,
    this.prunedDevices = 0,
  });

  final int seed;
  final bool converged;
  final List<FuzzDevice> devices;
  final int drainRounds;
  final String? failureReason;

  /// Compact actions run during the chaos phase.
  final int compactions;

  /// Snapshot files on the backend at the end.
  final int snapshotFiles;

  /// Devices whose log ended smaller than their coverage — ops really folded
  /// away into snapshots, their own or joined.
  final int prunedDevices;
}

/// Knobs for a run. Everything else derives from the seed.
class FuzzConfig {
  FuzzConfig({
    this.steps = 200,
    FaultConfig Function()? faults,
    this.faultsDuringDrain = false,
    this.maxDrainRounds = 64,
    this.onDrain,
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

  /// Called as the drain starts (unless [faultsDuringDrain]). Turn off faults
  /// injected BELOW the backend here — a fake server's 5xx, say. The drain
  /// must be honest: while a transient fault can still eat a download, a
  /// round that moves nothing does not mean everything has arrived.
  final void Function()? onDrain;

  static FaultConfig defaultFaults() => FaultConfig(
        truncatedUpload: 0.10,
        staleList: 0.20,
        delayedVisibility: 0.20,
        droppedUpload: 0.10,
        duplicateDelivery: 0.15,
      );
}

/// Run one fully deterministic fuzz iteration. The single [seed] fixes device
/// count, op sequence, sync ordering, compaction, and the entire fault
/// schedule.
///
/// Devices sync through [backend] (default: a fresh [MemoryBackend]) wrapped
/// in a [FaultyBackend]. Pass a real backend over EMPTY storage to put it
/// through the same fault fuzzer; it must be deterministic in listing order
/// for a seed to replay exactly.
///
/// Assertions, in order: quiescence; byte-identical merged state on every
/// device; identical coverage (the same op set held, as ops or snapshots);
/// every device's durable store reopens to the state it holds in memory; and,
/// throughout, causality — every stamp a device mints orders after every op
/// it holds.
Future<FuzzResult> runFuzz(
  int seed, {
  FuzzConfig? config,
  Backend? backend,
}) async {
  final cfg = config ?? FuzzConfig();
  final rng = Random(seed);
  final inner = backend ?? MemoryBackend();
  final faulty = FaultyBackend(inner, rng, faults: cfg.faults());

  final deviceCount = 2 + rng.nextInt(7); // 2..8
  final devices = <FuzzDevice>[
    for (var i = 0; i < deviceCount; i++) FuzzDevice._('d$i', MemoryStore()),
  ];

  // Causality oracle: the highest stamp of every op authored in this run.
  final stampOf = <String, Hlc>{};
  var compactions = 0;

  // Deterministic physical clock: a monotonic base tick plus each device's own
  // skew. Never wall-clock, so a seed reproduces every HLC exactly.
  var physicalTick = 0;
  Future<SyncClient> open(FuzzDevice dev) => SyncClient.open(
        backend: faulty,
        store: dev.store,
        deviceId: dev.id,
        physicalMillis: () => physicalTick + dev.clockSkewMs,
      );

  FuzzResult fail(String reason, int drainRounds) => FuzzResult(
        seed: seed,
        converged: false,
        devices: devices,
        drainRounds: drainRounds,
        failureReason: reason,
        compactions: compactions,
      );

  try {
    for (final dev in devices) {
      dev.client = await open(dev);
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
        final held = _maxHeld(dev, stampOf);
        final logBefore = client.ops.length;
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
            final ids = client.listElementIds(docId, 'items');
            final after = ids.isEmpty || rng.nextBool()
                ? null
                : ids[rng.nextInt(ids.length)];
            await client.insertIntoList(docId, 'items', _randomPayload(rng),
                after: after);
          default:
            // RGA delete of a random existing element, else insert instead.
            final ids = client.listElementIds(docId, 'items');
            if (ids.isEmpty) {
              await client.insertIntoList(docId, 'items', _randomPayload(rng));
            } else {
              await client.removeFromList(
                  docId, 'items', ids[rng.nextInt(ids.length)]);
            }
        }
        for (final op in client.ops.skip(logBefore)) {
          final (:minted, :max) = _stamps(op);
          if (max != null) stampOf[op.key] = max;
          if (minted != null && held != null && minted.compareTo(held) <= 0) {
            return fail(
                'causality: device ${dev.id} minted $minted, not after held '
                'stamp $held',
                0);
          }
        }
      } else if (roll < 82) {
        await client.sync(); // real merge round
      } else if (roll < 85) {
        await client.compact(); // snapshot, shed covered ops, publish
        compactions++;
      } else if (roll < 95) {
        dev.client = await open(dev); // crash: reopen from the store
      } else {
        dev.clockSkewMs += rng.nextInt(2001) - 1000; // +/- 1s skew
      }
    }

    // --- drain phase: sync rounds until quiescent ---
    if (!cfg.faultsDuringDrain) {
      faulty.faults = FaultConfig.none();
      cfg.onDrain?.call();
    }
    var quiescent = false;
    var rounds = 0;
    for (; rounds < cfg.maxDrainRounds; rounds++) {
      final before = _totalCoverage(devices);
      // Two passes, so a file the last device pushes reaches the first.
      for (var pass = 0; pass < 2; pass++) {
        for (final d in devices) {
          await d.client.sync();
        }
      }
      final pending = devices.fold(0, (n, d) => n + d.client.pendingUploads);
      if (_totalCoverage(devices) == before && pending == 0) {
        quiescent = true;
        rounds++;
        break;
      }
    }

    // --- convergence assertions ---
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

    // Secondary invariant: identical coverage (transport completeness). With
    // nothing compacted this is exactly op-log set equality.
    final refCoverage = devices.first.coverage;
    for (final d in devices.skip(1)) {
      if (!_listEqualString(refCoverage, d.coverage)) {
        return fail(
            'device ${d.id} coverage differs from ${devices.first.id}', rounds);
      }
    }

    // Durability: what each store holds reopens to what the device holds.
    for (final d in devices) {
      final reopened = await open(d);
      if (!_bytesEqual(reopened.materialize(), d.client.materialize())) {
        return fail(
            'device ${d.id}: store reopens to a different state', rounds);
      }
      if (!_listEqualString(_coverage(reopened), d.coverage)) {
        return fail(
            'device ${d.id}: store reopens to a different coverage', rounds);
      }
    }

    final snapshotFiles = (await inner.list())
        .where((f) => SnapshotFormat.parseFileName(f.name) != null)
        .length;
    return FuzzResult(
      seed: seed,
      converged: true,
      devices: devices,
      drainRounds: rounds,
      compactions: compactions,
      snapshotFiles: snapshotFiles,
      prunedDevices: devices.where((d) => d.logLength < d.coverageSize).length,
    );
  } on Object catch (e) {
    // Nothing in a fuzz run may throw: the backend's lies are all allowed.
    return fail('threw: $e', 0);
  }
}

/// The highest stamp among the ops [dev] holds — its coverage — looked up in
/// the run's own record of what each authored op carried.
Hlc? _maxHeld(FuzzDevice dev, Map<String, Hlc> stampOf) {
  Hlc? best;
  void see(String key) {
    final s = stampOf[key];
    if (s != null && (best == null || s.compareTo(best!) > 0)) best = s;
  }

  final frontier = dev.client.frontier;
  frontier.forEach((author, n) {
    for (var k = 0; k < n; k++) {
      see('$author#$k');
    }
  });
  for (final op in dev.client.ops) {
    if (op.seq >= (frontier[op.deviceId] ?? 0)) see(op.key);
  }
  return best;
}

/// The stamp an op mints (if its type mints one), and the highest stamp it
/// carries, minted or referenced.
({Hlc? minted, Hlc? max}) _stamps(Op op) {
  final Operation o;
  try {
    o = OperationCodec.decode(op.payload);
  } on FormatException {
    return (minted: null, max: null);
  }
  final (Hlc? minted, List<Hlc> all) = switch (o) {
    MapPut(:final hlc) => (hlc, <Hlc>[hlc]),
    SetAdd(:final tag) => (tag, <Hlc>[tag]),
    SetRemove(:final observedTags) => (null, observedTags),
    ListInsert(:final id, :final after) => (
        id,
        <Hlc>[id, if (after != null) after]
      ),
    ListDelete(:final elementId) => (null, <Hlc>[elementId]),
  };
  Hlc? max;
  for (final s in all) {
    if (max == null || s.compareTo(max) > 0) max = s;
  }
  return (minted: minted, max: max);
}

Uint8List _randomPayload(Random rng) {
  final len = 4 + rng.nextInt(13); // 4..16 bytes
  return Uint8List.fromList(
      <int>[for (var i = 0; i < len; i++) rng.nextInt(256)]);
}

/// One of a small set of OR-set elements, so adds and removes collide.
Uint8List _element(Random rng) =>
    Uint8List.fromList('t${rng.nextInt(5)}'.codeUnits);

int _totalCoverage(List<FuzzDevice> devices) =>
    devices.fold(0, (n, d) => n + d.coverageSize);

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _listEqualString(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
