# LT-5 contract-invariants: scenario and thresholds

Written before the first full run (the workspace's load standard); a miss is kept in
`perf/results`, never re-run until green.

**What runs.** `contracts/test/invariant/LMSRInvariants.t.sol`: a Foundry invariant campaign
over three funded markets (b = 1e18, the floor; b = 100e18; b = 1e30, the ceiling) and three
traders. The handler buys, sells, mints and burns complete sets (sizes: 1 wei dust, the
whole room left under `MAX_QUANTITY`, and log-uniform from 1 wei to ~1e6·b), does buy-then-sell
round trips, tries every points and outcome transfer path, and now and then closes, resolves
and redeems a market. After every call it checks:

| Invariant | Check |
|---|---|
| 1 Solvency | open: points held >= max(q); resolved: >= unredeemed winning shares |
| Subsidy bound | market-maker loss max(q) - (held - subsidy) <= ceil(b·ln 2), from `lmsr-ref` |
| 2 Prices | p0 + p1 = 1e18 exactly |
| 3 Round trips | no buy-then-sell of the same shares returns as many points as it cost |
| 7 Not money | no transfer, approve/transferFrom or outcome transfer moves points between accounts |
| Supply | outcome supply per id = the market's quantity |
| Conservation | points held by funder, markets and traders = total supply |

**Full scale.** `FOUNDRY_PROFILE=lt5`: 4,000 runs x depth 256 = 1,024,000 handler calls.

**Thresholds (all must hold):**

1. Handler calls >= 1,000,000.
2. Broken invariants = 0.
3. Handler reverts <= 1% of calls (the handler sizes every call to a valid one, so a revert
   is a contract refusal it did not expect).

Wall time is recorded but is not a threshold: it depends on the machine.

**Run:** `scripts/lt5.sh` (full, into `perf/results`) or `RUNS=64 DEPTH=32 scripts/lt5.sh`
(a plumbing probe, into `target/perf`). CI runs the full campaign on a hosted runner.
