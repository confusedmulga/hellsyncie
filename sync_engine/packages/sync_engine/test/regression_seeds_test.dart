import 'package:test/test.dart';

import 'harness/fuzz_driver.dart';
import 'regression_seeds.dart';

/// Runs every pinned regression seed. Auto-discovered by `dart test`.
void main() {
  group('regression seeds', () {
    if (regressionSeeds.isEmpty) {
      test('no pinned regression seeds yet', () {
        expect(regressionSeeds, isEmpty);
      });
    }
    for (final seed in regressionSeeds) {
      test('seed $seed converges', () async {
        final result = await runFuzz(seed);
        expect(result.converged, isTrue, reason: result.failureReason);
      });
    }
  });
}
