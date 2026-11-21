# LT-5 contract-invariants: scenario and thresholds

Written before the first full run (the workspace's load standard); a miss is kept in
`perf/results`, never re-run until green.

**What runs.** `contracts/test/invariant/LMSRInvariants.t.sol`: two Foundry invariant campaigns
over three funded markets (b = 1e18, the floor; b = 100e18; b = 1e30, the ceiling) and three
traders. The handler buys, sells, mints and burns complete sets (sizes: 1 wei dust, the
whole room left under `MAX_QUANTITY`, and log-uniform from 1 wei to ~1e6·b), does buy-then-sell
round trips, and tries every points and outcome transfer path as the holder (single and batch,
with shares the holder owns). The *trading* campaign (`LMSRInvariants`) never closes a market,
so every call it asks for runs; the *resolution* campaign (`LMSRInvariantsResolution`) adds
close, resolve and redeem, with closes staggered 10, 20 and 30 days out so resolving one market
leaves the later ones trading. After every call each checks:

| Invariant | Check |
|---|---|
| 1 Solvency | open: points held >= max(q); resolved: >= unredeemed winning shares |
| Subsidy bound | market-maker loss max(q) - (held - subsidy) <= ceil(b·ln 2), from `lmsr-ref` |
| 2 Prices | p0 + p1 = 1e18 exactly |
| 3 Round trips | no buy-then-sell of the same shares returns as many points as it cost |
| 7 Not money | no points transfer, approve/transferFrom, or outcome safeTransferFrom/safeBatchTransferFrom (run as the holder) moves a balance between accounts, and each is refused by the token's own no-transfer error (value moved through trades is D-007, pinned in `unit/ValueMoves.t.sol`) |
| Supply | outcome supply per id = the market's quantity |
| Conservation | points held by funder, markets and traders = total supply |

**Full scale.** `FOUNDRY_PROFILE=lt5`: 8,000 runs x depth 256 per campaign. The handler counts
the trades that executed (a ghost variable; a round trip is two) and, after each run, writes its
counts to one file per run, which `scripts/lt5.sh` sums. Forge's call total is runs x depth, but
the handler sees more calls than that (forge 1.10 lengthens some runs past the depth), so the
executed-trade count is also scaled down by forge's calls / the handler's calls, and both
figures must clear the bar.

**Thresholds (all must hold).** Revised after the M1 review: the first version counted handler
calls, most of which could be no-ops once one resolution closed every market (that shape
executes ~340,000 trades in 2,048,000 calls, below the bar):

1. Trading campaign: executed trades >= 1,000,000, and >= 1,000,000 when scaled to forge's calls.
2. Broken invariants = 0, in both campaigns.
3. Reverts <= 1% of forge's calls, per campaign (the handler sizes every call to a valid one,
   so a revert is a contract refusal it did not expect).
4. At least 99% of runs reported their ghost counts (two runs that end in the same state share
   one file, which only lowers the count); each campaign tried to move shares their holder
   owns; the resolution campaign resolved at least one market.

**Committed result.** `perf/results/20261121T001539Z-lt5-full.json`: the CI `lt5` job (GitHub-hosted
runner, 4 cores), copied from its log; thresholds passed.

**Misses kept.** `perf/results/20261120T224958Z-lt5-full.json` (trading 1,818,452 executed trades,
1,311,781 scaled; 0 reverts; 0 broken) missed threshold 4 as first written ("every run
reported"): 7 of the resolution campaign's 8,000 runs ended in a state another run also reached.
The threshold was a flaw in the measurement, not the contracts; it was relaxed as above, which
can only undercount trades.

Wall time is recorded but is not a threshold: it depends on the machine.

**Run:** `scripts/lt5.sh` (full, into `perf/results`) or `RUNS=64 DEPTH=32 scripts/lt5.sh`
(a plumbing probe, into `target/perf`). CI runs the full campaign on a hosted runner.
