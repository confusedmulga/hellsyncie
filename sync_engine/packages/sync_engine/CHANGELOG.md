# Changelog

## 0.1.0

- Scaffold + simulation harness.
- `Backend` four-method contract (production interface).
- Versioned op-file format with CRC-32; corrupt/truncated files are rejected.
- `SimulatedBackend` with five independently controllable fault modes.
- `SimulatedDevice` with durable op log, unconfirmed-upload retry, crash/restart.
- Deterministic seeded fuzz driver + CLI + 1000-iteration test.
- No CRDT engine yet — convergence asserted by op-log set equality.
