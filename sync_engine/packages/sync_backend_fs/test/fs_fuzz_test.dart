import 'dart:io';
import 'dart:math';

import 'package:sync_backend_fs/sync_backend_fs.dart';
import 'package:sync_engine/testing.dart';
import 'package:test/test.dart';

/// The same seeded fault fuzzer the engine is gated on, driving real sync
/// clients through a real folder. Faults are layered over [FsBackend], so
/// truncated uploads leave real partial files on disk.
void main() {
  test(
    '100 random seeds converge over FsBackend under fault injection',
    () async {
      final meta = Random();
      final failing = <String>[];
      for (var i = 0; i < 100; i++) {
        final seed = meta.nextInt(0x7fffffff);
        final dir = await Directory.systemTemp.createTemp('hsy_fs_fuzz_');
        try {
          final result = await runFuzz(seed, backend: FsBackend(dir));
          if (!result.converged) failing.add('$seed (${result.failureReason})');
        } finally {
          await dir.delete(recursive: true);
        }
      }
      expect(
        failing,
        isEmpty,
        reason: 'Non-converging seeds over FsBackend. Pin each in '
            'sync_engine/test/regression_seeds.dart and fix the cause, never '
            'the assertion: $failing',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
