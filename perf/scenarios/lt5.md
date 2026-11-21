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

**Full scale.** `FOUNDRY_PROFILE=lt5`: 8,000 runs x depth 256 per campaign, with a fuzz seed
`scripts/lt5.sh` draws (or takes from `SEED`), passes as `--fuzz-seed` and records in the result,
so a campaign can be replayed. The handler counts the trades that executed (a ghost variable; a
round trip is two) and keeps a running keccak of every call's `msg.data`. After each run
`afterInvariant` appends one line (`vm.writeLine`, append under a file lock) to its campaign's
file: a fingerprint that folds that call chain into the end state, then the counts over the
run's own last `depth` calls. Forge 1.10 resumes most runs from a snapshot of an earlier run,
whose prefix calls that run already counted; the first version summed the handler's cumulative
counts, so it counted prefixes again (that, not longer runs, is why its handler calls, 2,750,602,
exceeded forge's 2,048,000; a 200 x 64 probe at the PR head: 21,362 handler calls for forge's
12,800, and 12,800 for 12,800 with per-run counts). Forge then replays its last run once for
traces, which appends that run's line again with the same fingerprint; `scripts/lt5.sh` counts
each fingerprint once, so with 0 reverts the handler's calls equal forge's. The executed-trade
count is also scaled by forge's calls / the handler's calls, and both figures must clear the bar.

**Thresholds (all must hold).** Revised after the M1 review: the first version counted handler
calls, most of which could be no-ops once one resolution closed every market (that shape
executes ~340,000 trades in 2,048,000 calls, below the bar):

1. Trading campaign: executed trades >= 1,000,000, and >= 1,000,000 when scaled to forge's calls.
2. Broken invariants = 0, in both campaigns.
3. Reverts <= 1% of forge's calls, per campaign (the handler sizes every call to a valid one,
   so a revert is a contract refusal it did not expect).
4. Every run reported: the distinct fingerprints equal forge's runs exactly, with at most one
   repeated line (forge's trace replay of its last run); each campaign tried to move shares
   their holder owns; the resolution campaign resolved at least one market.

**Committed result.** The CI `lt5` job's result for this measurement (GitHub-hosted runner, 4
cores) is copied from its log into `perf/results` when it runs; until then M1's LT-5 is not
evidenced. `perf/results/20261121T001539Z-lt5-full.json` passed only the relaxed threshold
(7,985 of 8,000 resolution runs reported) and counted snapshot prefixes again, so it is kept
below as a miss.

**Misses kept.** `perf/results/20261120T224958Z-lt5-full.json` (trading 1,818,452 executed trades,
1,311,781 scaled; 0 reverts; 0 broken) missed threshold 4 as first written ("every run
reported"): files were named by a hash of the run's end state, and 7 of the resolution
campaign's 8,000 runs ended in a state another run also reached. Threshold 4 was then relaxed
to 99%, a threshold moved after measuring, which is reverted here: the measurement was made
exact instead (above). `perf/results/20261121T002737Z-lt5-full.json` (the CI `lt5` job on PR
merge commit bbf8230; trading 1,906,879 executed trades, 1,419,793 scaled; 0 reverts; 19
invariants, 0 broken) missed the relaxed threshold too: 7,898 of the resolution campaign's 8,000
runs reported (98.73%), the same end-state collisions. `20261121T001539Z` (PR merge commit
be1ca60) passed the relaxed threshold with 7,985 of 8,000 and misses the reverted one. None of
the three recorded its seed.

Wall time is recorded but is not a threshold: it depends on the machine.

**Run:** `scripts/lt5.sh` (full, into `perf/results`) or `RUNS=64 DEPTH=32 scripts/lt5.sh`
(a plumbing probe, into `target/perf`). CI runs the full campaign on a hosted runner.
