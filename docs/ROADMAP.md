# Niche Prediction Market — roadmap

M0 is this base setup; the later milestones come from the end goal (`docs/END_GOAL.md`,
mapped from the spec's weeks). A milestone's status cell says *Done* only with named
tests and evidence.

| M | Spec week | Deliverable | Gate | Status |
|---|---|---|---|---|
| M0 | — | Base setup from the starter template: CI, gate, port band 63100–63199, drills and evidence kit, `contracts/` shell | CI green on the empty product | **In progress — this base setup** |
| M1 | 1 | LMSR in Solidity (stable form) + `lmsr-ref`; outcome and points tokens | Differential fuzz agrees; LT-5 at full scale | Planned |
| M2 | 2 | Factory, resolver (early close, INVALID, timeout), redeem | Full lifecycle in Foundry; failure cases 4–7 | Planned |
| M3 | 3 | Indexer: safe-head follow, checkpoints, reorgs; schema | Failure cases 8–11; LT-3 | Planned |
| M4 | 4 | API + SSE + trading UI on Base Sepolia | Trade and redeem from the UI; LT-1, LT-2, LT-4 | Planned |
| M5 | 5 | Creation, moderation, leaderboard, faucet | LT-6; failure cases 13–15 | Planned |
| M6 | 6–7 | OG images, docs site and changelog, deploy, UI audit, security review, users | Ship gate checked | Planned |
