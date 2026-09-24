import 'dart:math';

import 'package:sync_engine/testing.dart';
import 'package:test/test.dart';

void main() {
  test(
    '1000 random seeds converge under fault injection',
    () async {
      final meta = Random();
      final failing = <int>[];
      var compactions = 0, snapshotFiles = 0, prunedDevices = 0;
      var deletedOps = 0, sleeperRunsWithDeletion = 0;
      for (var i = 0; i < 1000; i++) {
        final seed = meta.nextInt(0x7fffffff);
        final result = await runFuzz(seed);
        if (!result.converged) failing.add(seed);
        compactions += result.compactions;
        snapshotFiles += result.snapshotFiles;
        prunedDevices += result.prunedDevices;
        deletedOps += result.deletedOps;
        if (result.sleeper != null && result.deletedOps > 0) {
          sleeperRunsWithDeletion++;
        }
      }
      // Guard against a vacuous pass: compaction really ran, snapshots landed
      // on the backend, logs really shrank into them, op files really were
      // deleted — including past a sleeping device that then had to catch up.
      expect(compactions, greaterThan(1000));
      expect(snapshotFiles, greaterThan(500));
      expect(prunedDevices, greaterThan(500));
      expect(deletedOps, greaterThan(1000));
      expect(sleeperRunsWithDeletion, greaterThan(50));
      expect(
        failing,
        isEmpty,
        reason: 'Non-converging seeds — an engine bug. Pin each in '
            'regression_seeds.dart and fix the engine, never the assertion: '
            '$failing',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
