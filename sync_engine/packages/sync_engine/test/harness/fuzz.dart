// CLI entry for the convergence fuzzer.
//
//   dart run test/harness/fuzz.dart --seed=42
//   dart run test/harness/fuzz.dart --seed=42 --iterations=1000
//   dart run test/harness/fuzz.dart --force-fault=dropped:1.0   # demo a failure
//
// On failure the seed is printed prominently and per-device op logs are dumped
// to ./.fuzz_failures/seed_<seed>/ for replay.
import 'dart:convert';
import 'dart:io';

import 'package:sync_engine/testing.dart';

Future<void> main(List<String> args) async {
  var seed = DateTime.now().millisecondsSinceEpoch & 0x7fffffff;
  var iterations = 1;
  var steps = 200;
  String? forceFault;
  var faultsDuringDrain = false;

  for (final a in args) {
    if (a.startsWith('--seed=')) {
      seed = int.parse(a.substring('--seed='.length));
    } else if (a.startsWith('--iterations=')) {
      iterations = int.parse(a.substring('--iterations='.length));
    } else if (a.startsWith('--steps=')) {
      steps = int.parse(a.substring('--steps='.length));
    } else if (a.startsWith('--force-fault=')) {
      forceFault = a.substring('--force-fault='.length);
      faultsDuringDrain = true; // hold the fault through the drain to force it
    } else if (a == '--faults-during-drain') {
      faultsDuringDrain = true;
    } else if (a == '-h' || a == '--help') {
      _printUsage();
      return;
    } else {
      stderr.writeln('unknown argument: $a');
      _printUsage();
      exitCode = 64;
      return;
    }
  }

  FuzzConfig makeConfig() => FuzzConfig(
        steps: steps,
        faultsDuringDrain: faultsDuringDrain,
        faults: () => _buildFaults(forceFault),
      );

  var failures = 0;
  for (var i = 0; i < iterations; i++) {
    final runSeed = iterations == 1 ? seed : seed + i;
    final result = await runFuzz(runSeed, config: makeConfig());
    if (!result.converged) {
      failures++;
      _reportFailure(result, forceFault: forceFault);
    }
  }

  if (iterations == 1) {
    if (failures == 0) {
      stdout.writeln('seed $seed: CONVERGED — all devices byte-identical.');
    } else {
      exitCode = 1;
    }
  } else {
    stdout.writeln(
      'ran $iterations iterations from base seed $seed: '
      '${iterations - failures} converged, $failures FAILED.',
    );
    if (failures > 0) exitCode = 1;
  }
}

FaultConfig _buildFaults(String? forceFault) {
  if (forceFault == null) return FuzzConfig.defaultFaults();

  final parts = forceFault.split(':');
  final name = parts[0];
  final prob = parts.length > 1 ? double.parse(parts[1]) : 1.0;
  final f = FaultConfig();
  switch (name) {
    case 'truncated':
      f.truncatedUpload = prob;
    case 'stale':
      f.staleList = prob;
    case 'delayed':
      f.delayedVisibility = prob;
    case 'dropped':
      f.droppedUpload = prob;
    case 'duplicate':
      f.duplicateDelivery = prob;
    default:
      stderr.writeln('unknown fault: $name '
          '(truncated|stale|delayed|dropped|duplicate)');
      exit(64);
  }
  return f;
}

void _reportFailure(FuzzResult result, {String? forceFault}) {
  final dir = Directory('.fuzz_failures/seed_${result.seed}')
    ..createSync(recursive: true);

  final repro =
      StringBuffer('dart run test/harness/fuzz.dart --seed=${result.seed}');
  if (forceFault != null) repro.write(' --force-fault=$forceFault');

  const bar =
      '================================================================';
  stderr
    ..writeln(bar)
    ..writeln('  FUZZ CONVERGENCE FAILURE')
    ..writeln('  SEED     = ${result.seed}')
    ..writeln('  DEVICES  = ${result.devices.length}')
    ..writeln('  REASON   = ${result.failureReason}')
    ..writeln('  REPRODUCE: $repro')
    ..writeln('  OP LOGS  -> ${dir.path}${Platform.pathSeparator}')
    ..writeln(bar);

  final summary = StringBuffer()
    ..writeln('seed: ${result.seed}')
    ..writeln('devices: ${result.devices.length}')
    ..writeln('drain_rounds: ${result.drainRounds}')
    ..writeln('reason: ${result.failureReason}')
    ..writeln('reproduce: $repro');
  File('${dir.path}/summary.txt').writeAsStringSync(summary.toString());

  for (final d in result.devices) {
    final sb = StringBuffer('device ${d.id} — ${d.logLength} ops\n');
    for (final op in d.log) {
      sb.writeln('${op.key}\t${_hex(op.payload)}');
    }
    File('${dir.path}/device_${d.id}.log').writeAsStringSync(sb.toString());
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void _printUsage() {
  stdout.writeln(const LineSplitter().convert('''
hellsyncie convergence fuzzer

  --seed=N              fixed seed (default: time-based)
  --iterations=N        run N seeds from base seed (default: 1)
  --steps=N             chaos steps per run (default: 200)
  --force-fault=NAME[:P]  hold one fault at probability P through the drain to
                          demonstrate the failure path. NAME is one of:
                          truncated | stale | delayed | dropped | duplicate
  --faults-during-drain keep the default fault mix active during the drain
  -h, --help            this message
''').join('\n'));
}
