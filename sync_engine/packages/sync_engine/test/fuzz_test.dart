import 'dart:math';

import 'package:test/test.dart';

import 'harness/fuzz_driver.dart';

void main() {
  test(
    '1000 random seeds converge under fault injection',
    () async {
      final meta = Random();
      final failing = <int>[];
      for (var i = 0; i < 1000; i++) {
        final seed = meta.nextInt(0x7fffffff);
        final result = await runFuzz(seed);
        if (!result.converged) failing.add(seed);
      }
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
