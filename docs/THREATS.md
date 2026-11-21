# Niche Prediction Market — threats

Known attack paths against the product and what bounds each. A row names the decision
(`DECISIONS.md`) and the test that pins it; *open* means tracked to a milestone, not yet
bounded in code.

| Id | Threat | Bound | Pinned by | Status |
|---|---|---|---|---|
| T-1 | Two accounts move points between each other through any open market at almost no cost: A buys D of one outcome, B the other, both sell; B gains about `D − 2·b·ln 2`, the pair pays only rounding margins (264 wei at b = 1e18, D = 1e6 points). Enables sybil faucet farming, leaderboard inflation by points, off-app sales of points. Inherent to any AMM; the cost does not grow with D. | Points confer no rank (D-007); the leaderboard ranks Brier skill on resolved positions, never points (D-008); faucet caps per identity (LT-6, D-008). Token calls still cannot move points or shares between accounts (invariant 7). | `contracts/test/unit/ValueMoves.t.sol`; LT-5 invariant 7 | Accepted, documented; leaderboard and faucet bounds at M5 |
| T-2 | One admin key drains every account: `DEFAULT_ADMIN_ROLE` grants `MARKET_ROLE` to an EOA, which calls `PointsToken.pull(victim, …)`; `registerMarket` cannot be undone. | The factory is the only grantor; admin renounced or behind a timelocked multisig (D-009). | — | Open, M2 |
| T-3 | EIP-1167 clones share the implementation's immutables, so every clone would have one `b`, `closeTime` and `resolver`. | Full CREATE2 deploys, or a guarded initializer with a locked implementation (D-009). | — | Open, M2 |
| T-4 | Points lock: no cancel, INVALID or timeout; leftover subsidy never returned; a lost resolver key locks redemption; the resolver may trade its own market. | Cancel/INVALID/timeout, subsidy return, resolver cannot trade (D-009). | — | Open, M2 |
