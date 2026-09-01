/// Seeds that once exposed a convergence failure. These are PERMANENT.
///
/// Rules (see CLAUDE.md):
///  - The instant the fuzzer prints a failing seed, add it to [regressionSeeds].
///  - NEVER delete an entry. NEVER weaken the assertion to make it pass.
///  - A failing seed means an engine bug. Fix the engine.
///
/// This file is DATA only, so seeds are committed here exactly as the brief
/// says. The runner that executes them is `regression_seeds_test.dart` (a
/// `_test.dart` file so `dart test` auto-discovers it).
library;

const List<int> regressionSeeds = <int>[
  // (none yet — the transport layer is fault-tolerant by construction at this
  //  stage; the first real engine bug's seed lands here.)
];
