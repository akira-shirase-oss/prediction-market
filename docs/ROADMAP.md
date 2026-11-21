# Niche Prediction Market — roadmap

M0 is this base setup; the later milestones come from the end goal (`docs/END_GOAL.md`,
mapped from the spec's weeks). A milestone's status cell says *Done* only with named
tests and evidence.

| M | Spec week | Deliverable | Gate | Status |
|---|---|---|---|---|
| M0 | — | Base setup from the starter template: CI, gate, port band 63100–63199, drills and evidence kit, `contracts/` shell | CI green on the empty product | **In progress — this base setup** |
| M1 | 1 | LMSR in Solidity (stable form) + `lmsr-ref`; outcome and points tokens | Differential fuzz agrees; LT-5 at full scale | Done — `contracts/test/differential/Differential.t.sol` (10,000 runs; the dense sweep, 4,048 states, asserts cost error ≤ 16 wei per 1e18 of b against a 32 budget, measured 14), refusals in `contracts/test/unit/` (each protection proven by `scripts/prove-contracts.sh`), the A-to-B move pinned in `contracts/test/unit/ValueMoves.t.sol` (D-007), LT-5 `scripts/lt5.sh`, CI job `lt5`: `perf/results/20261121T114817Z-lt5-full.json` (GitHub-hosted runner, PR merge commit f48ed65, seed recorded: 8,000 of 8,000 runs reported per campaign; 1,470,197 executed trades in the trading campaign, handler calls equal to forge's; 1,744 resolutions; 0 reverts, 19 invariants, 0 broken; the three earlier results are misses, `perf/scenarios/lt5.md`) |
| M2 | 2 | Factory, resolver (early close, INVALID, timeout), redeem; from the M1 review (D-009, `THREATS.md` T-2–T-4): the factory the only `MARKET_ROLE` grantor with the admin renounced or behind a timelocked multisig, full CREATE2 deploys or a guarded initializer with a locked implementation (no clones over immutables), cancel/INVALID/timeout, subsidy return, a resolver that cannot trade | Full lifecycle in Foundry; failure cases 4–7 | Planned |
| M3 | 3 | Indexer: safe-head follow, checkpoints, reorgs; schema | Failure cases 8–11; LT-3 | Planned |
| M4 | 4 | API + SSE + trading UI on Base Sepolia | Trade and redeem from the UI; LT-1, LT-2, LT-4 | Planned |
| M5 | 5 | Creation, moderation, leaderboard, faucet; the leaderboard ranks forecasting skill by Brier score on each account's resolved positions, never points balance or points profit (D-007, D-008); faucet caps per identity (LT-6) | LT-6; failure cases 13–15 | Planned |
| M6 | 6–7 | OG images, docs site and changelog, deploy, UI audit, security review, users | Ship gate checked | Planned |
