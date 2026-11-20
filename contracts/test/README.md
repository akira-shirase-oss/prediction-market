# test/

- `unit/` — every refusal (overflow, zero or negative amounts, closed or resolved markets,
  pool-favouring rounding, access control, reentrancy) and the KNOWLEDGE.md worked example.
- `differential/` — the M1 exit gate: the same trades into `LMSRMarket` and `lmsr-ref`
  (via `vm.ffi`, profile `diff`, run by `scripts/check-contracts.sh`).
- `invariant/` — LT-5 (`perf/scenarios/lt5.md`, `scripts/lt5.sh`): solvency, loss ≤ b·ln 2,
  prices sum to 1e18, no profitable round trip, no token call moves points or shares between accounts, a pair moving value through a market is pinned (`unit/ValueMoves.t.sol`), supply matches q.
