# Niche Prediction Market: end goal

**Every market's price is always quoted, its collateral always covers every possible payout, and every resolution can
be traced from proposal to final outcome.**

This is a play-money prediction market for one community. Members create and trade yes/no markets about events in one
niche. An LMSR automated market maker quotes a price even when only one person trades, and a creator-funded subsidy
bounds the market maker's loss to `b·ln(n)`. Markets are resolved optimistically: a bonded proposal, a dispute window,
and a documented arbiter. Contracts run on Base Sepolia (Solidity + Foundry). A Rust indexer turns contract events into
Postgres rows. A Rust API serves markets, portfolios, leaderboards and live prices to a SvelteKit app. Collateral is
non-transferable points with no cash value. The portfolio value is the mechanism design, the proof that the maths and
the indexer are correct, and a trading UI a casual community member can use.

**Origin.** The v2.0 spec (02_Niche_Prediction_Market_dApp, 2026-11-20) merged with the repository rules
(`akira-shirase-oss/AGENTS.md`). Facts and corrections are in `KNOWLEDGE.md` next to this file. Every number below is
either quoted from the spec (marked) or a proposed target for the maintainer to confirm. None is a measurement.

## Users and the job to be done

- **Community member (trader):** "Tell me what people here believe will happen, and let me put my view on record
  without risking money." Arrives from a shared link, gets points from a faucet, trades, and later redeems.
- **Market creator:** "Ask a clear question that resolves without argument." Writes the question, rules and resolution
  source, funds the subsidy, and waits for moderation.
- **Resolver and arbiter:** "Settle outcomes fairly and visibly." Proposes, disputes, rules, and closes early or
  declares a market invalid.
- **A reviewer of the portfolio:** "Show me the mechanism is correct and the system is reliable." Reads `MECHANISM.md`,
  the invariant and differential test results, and the load results.

## v1 scope

- **Binary LMSR markets** with a fixed `b` per market. The creator deposits at least `ceil(b·ln 2)` points. Buy and sell
  carry `maxCost`/`minReturn` guards. A trading fee is charged on top of the LMSR cost and held outside the cost
  function (the spec says 1–2%).
- **ERC-1155 outcome tokens.** One unit of collateral mints a complete set, and a complete set burns back to one unit.
- **Resolution lifecycle:** OPEN → CLOSED → PROPOSED → (DISPUTED → arbiter ruling) → FINALISED → redeem. v1 adds three
  paths the spec lacks:
  - an early close the resolver can call when the event happens before `closeTime`;
  - an **INVALID** outcome with a refund rule fixed at creation;
  - a no-proposer timeout that lets the arbiter propose.
  The dispute window is 24 h (the spec says). The arbiter is a multisig, documented as a trust assumption.
- **Points collateral:** non-transferable except into markets and back, never redeemable for anything outside the app.
  A rate-limited faucet mints it (section 8 of `KNOWLEDGE.md`).
- **Rust indexer:**
  - follows `safe` blocks by default (`latest` shown as provisional);
  - checkpoints and detects reorgs by block hash;
  - upserts idempotently;
  - orders events by `(block_number, log_index)`, because Base produces about five 200 ms blocks per timestamp second.
- **Rust API (Axum):**
  - market metadata stored off-chain with its hash on-chain;
  - moderation queue;
  - market, price-history, portfolio and leaderboard reads;
  - instant quotes from `lmsr-ref`;
  - SSE price stream with heartbeats under Cloudflare's 100 s timeout;
  - OG images with `resvg`.
- **SvelteKit app:** markets, a market page (chart, rules, resolution status, activity), trade with a slippage preview,
  portfolio and redeem, create, moderation, resolution console, leaderboard (Brier and profit), and an
  indexer/chain status page.
- **Docs and evidence:** `MECHANISM.md` (the LMSR worked example from `KNOWLEDGE.md`, the solvency proof, charts),
  `ARCHITECTURE.md`, `THREATS.md`, the Starlight docs site, and the changelog.

## Later (each needs its own gate)

- Liquidity provision with LP shares. This conflicts with fixed-`b` LMSR and needs a new mechanism decision.
- Gasless onboarding (ERC-4337 or EIP-7702 smart accounts plus a paymaster): spec P1, a third-party dependency.
- Multi-outcome markets (3–8 outcomes) and scalar markets.
- UMA OOv3 as the escalation path. On Base Sepolia it resolves disputes through a mock oracle anyone can push to, so it
  shows integration code only.
- AI market assistant (ambiguity checks), the embeddable widget, and private internal-forecasting mode.

## Non-goals

- **Real money in any form:** no fiat ramp, no redeemable or transferable collateral, no prizes of value, no paid
  market creation, no fee revenue. India's Online Gaming Act 2025 counts "credits, coins, token" convertible to money as
  stakes (`KNOWLEDGE.md` §8).
- A CLOB or off-chain matching.
- Mainnet deployment.
- An on-chain enforcement claim the system cannot make, for example "creators cannot trade their own markets"
  (sybil-trivial). It is disclosed instead.

## Architecture in brief

```
SvelteKit app ──viem/@wagmi/core──► MarketFactory ─► LMSRMarket (clone per market) ─► OutcomeToken (ERC-1155)
     │                                                 Resolver (bonded, multisig arbiter)    PointsToken (non-transferable)
     │ REST + SSE                                             │ logs
     ▼                                                        ▼
Rust API (Axum, Tower: timeouts, body limits, rate limits, tracing) ◄── Postgres ◄── Rust indexer (alloy 2.x; safe-head
     └── lmsr-ref (quotes; also the Foundry FFI oracle)                                 follow, reorg walk-back, checkpoint)
```

Cargo workspace: `crates/{indexer, api, lmsr-ref, chain, db}`, `contracts/` (Foundry, OpenZeppelin 5.x, PRBMath v4),
`web/` (SvelteKit + TypeScript strict + Tailwind v4 + shadcn-svelte), `perf/`, `docs/`. The workspace hosting rule
serves the API and the app from one origin on the product's droplet, under systemd behind Caddy, with Cloudflare in
front. The spec instead puts the app on Cloudflare Pages and the services in Docker Compose. See the open questions.

## Invariants

1. **Solvency:** points held by a market ≥ its largest outstanding outcome quantity + accrued fees, after every
   transaction. Rounding always favours the pool.
2. **Prices:** each market's prices sum to 1e18 within a documented tolerance, and no price is negative.
3. **Round trips never profit:** any sequence of buys and sells that returns a trader's position to where it started
   leaves them with no more points than before, fees excluded.
4. **Lifecycle:** no trade after close; no redeem before FINALISED or INVALID; one final outcome per market.
5. **Bonds:** bonds in = bonds returned + bonds slashed + bonds held, per market.
6. **Indexer:** the database state is a pure function of the canonical chain up to the checkpoint, identical whatever
   the batch sizes and restarts.
7. **Collateral is not money:** the points token has no transfer path except into and out of markets.

## Required failure cases (each has a test)

| # | Trigger | Required result | Proven by |
|---|---|---|---|
| 1 | Random buy/sell sequences, including dust and boundary sizes | Invariants 1–3 hold | Foundry invariant campaign (part of LT-5) and fuzz tests |
| 2 | Quantities far apart (price near 0 or 1); exponent below PRBMath's −41.45 threshold | No revert in the stable form; zero-price outcomes handled; shares-for-spend never divides by zero | Boundary unit tests in Solidity and Rust |
| 3 | Solidity and `lmsr-ref` disagree beyond tolerance | The test fails and names the inputs | FFI differential fuzz; tolerance set from measured error |
| 4 | Trade after `closeTime`; redeem before final; double redeem | Revert with a named error | Lifecycle unit tests |
| 5 | Event happens before `closeTime` | The resolver's early close stops trading at the recorded block | `early_close_stops_trading` |
| 6 | Wrong proposal, then a correct dispute | The arbiter overturns it; bonds move as specified; invariant 5 holds | Full-lifecycle Foundry test |
| 7 | No one proposes within the timeout; an ambiguous market | The arbiter proposes; INVALID refunds by the creation-time rule | `no_proposer_timeout`, `invalid_refunds` |
| 8 | Chain reorg below the indexer's head | Derived rows above the common ancestor are replaced; no duplicates | Recorded fork fixture replay |
| 9 | Indexer killed mid-batch at seeded points | It resumes from the checkpoint; the final digest equals an uninterrupted run | `kill-mid-batch` drill with `SIGKILL` |
| 10 | RPC returns errors, rate limits or hangs | Bounded retries with backoff; `/readyz` reports lag; the UI shows "data delayed" | RPC fault-injection proxy test |
| 11 | Chain stalls (Base halted about 116 min in June 2026) | The UI says "chain stalled", separate from "indexer stalled"; nothing is marked final early | Stalled-head fixture |
| 12 | A slow SSE consumer | Bounded channel; the client gets a `resync` event; server memory stays flat | Part of LT-2 |
| 13 | Faucet abuse from many addresses and IPs | Quotas hold; mints equal the ledger | LT-6 |
| 14 | Points transfer to an outside address | Revert | `points_are_not_transferable` |
| 15 | Hostile market text (script in the question, oversized rules) | Escaped in the UI and OG images; refused above size limits | API and Playwright tests |

## Ship gate

All of these hold on the release commit:

- [ ] CI green on every push:
  - Rust: `cargo fmt --check`, `clippy -D warnings`, `cargo nextest`, `cargo-deny`, `cargo-audit`,
    `sqlx prepare --check`, and coverage;
  - contracts: `forge fmt --check`, `forge test`, and the invariant campaign;
  - web: SvelteKit `check`, `lint` and `build`;
  - an architecture check.
- [ ] Playwright E2E on Anvil: create → moderate → trade → close → propose → dispute → rule → redeem, plus INVALID
  refund.
- [ ] **Load scenarios.** Each runs at least 1,000,000 units on CI (full) and is committed under `perf/results/` with
  machine, commit and `uptime`. The thresholds below are proposed. A miss is evidence, and changing a threshold needs a
  decision entry.
  - **LT-1 market-reads:** 1,000,000 HTTP reads (lists, market pages, price history, portfolios, quotes) at a fixed
    arrival rate. Error rate < 0.1%; p99 recorded against a target set from the M0 baseline.
  - **LT-2 price-stream:** 1,000,000 price events delivered across at least 5,000 concurrent SSE clients. p99 lag from
    indexer commit to client receipt ≤ 1 s; RSS plateaus; slow clients get `resync`.
  - **LT-3 indexer-replay:** 1,000,000 synthetic `Trade` logs from a recorded Anvil chain. Database digest identical for
    batch sizes {1, 7, 100, 2,000}; throughput at least 10× the observed event rate, sized for 5 blocks/s.
  - **LT-4 quote:** 1,000,000 `lmsr-ref` quotes through the API. Results match the contract's `quoteBuy` within
    tolerance on a sampled 1%.
  - **LT-5 contract-invariants:** at least 1,000,000 handler calls (runs × depth). Zero invariant failures.
  - **LT-6 faucet-abuse:** 1,000,000 faucet requests from 10,000 synthetic identities. Zero over-quota mints.
- [ ] All 15 failure cases pass. `THREATS.md` covers contracts, indexer, API and faucet. Static analysis runs on the
  contracts (tool choice is an open question). An independent review of the contracts and indexer has its findings
  closed or accepted in `DECISIONS.md`.
- [ ] Docs site `prediction-market-docs` (Astro Starlight, Cloudflare Pages): quick start ending in a real API call,
  concepts (LMSR, resolution, points), feature guides, API reference from OpenAPI, self-hosting, and a `/changelog`.
  Examples run in CI.
- [ ] UI covers every operation:
  - trading: create, approve or reject, trade, redeem;
  - resolution: propose, dispute, rule, early close, INVALID;
  - supporting: faucet, portfolio, leaderboard, indexer/chain status.
  - UI audit at 1440 and 390 px, light and dark, by role.
- [ ] Live deployment that works without the laptop:
  - contracts verified on Base Sepolia;
  - API, indexer and app on the droplet; landing and docs on Pages;
  - `/healthz` and `/readyz` watched by Service Monitor;
  - nightly backup and a restore drill;
  - seed markets, so the first screen is never empty.
- [ ] Overview Definition of Done:
  - README with a 60–90 s demo, architecture diagram, quick start, live URL and known limitations;
  - CI badge and coverage, and performance numbers;
  - `ARCHITECTURE.md` with rejected trade-offs, and `MECHANISM.md`;
  - build post;
  - clean history, `.env.example`, MIT or Apache-2.0.
- [ ] Community evidence (the spec says): 20+ markets, 50+ traders, 10 real test users. The Brier score on resolved
  markets is reported with the number of markets; "< 0.25" means better than a constant 50% forecast.

## Milestones (the spec's weeks, with workspace standards added)

| M | Spec week | Deliverables | Done when |
|---|---|---|---|
| M0 | before week 1 | Workspace, CI, perf harness with one LT at small scale, one failure drill, docs skeleton | CI green; the drill runs in CI |
| M1 | 1 | LMSR in Solidity (stable form) + `lmsr-ref`; outcome and points tokens | Differential fuzz agrees; LT-5 at full scale |
| M2 | 2 | Factory, resolver (early close, INVALID, timeout), redeem | Full lifecycle in Foundry; failure cases 4–7 |
| M3 | 3 | Indexer: safe-head follow, checkpoints, reorgs; schema | Failure cases 8–11; LT-3 |
| M4 | 4 | API + SSE + trading UI on Base Sepolia | Trade and redeem from the UI; LT-1, LT-2, LT-4 |
| M5 | 5 | Creation, moderation, leaderboard, faucet | LT-6; failure cases 13–15 |
| M6 | 6–7 | OG images, docs site and changelog, deploy, UI audit, security review, users | Ship gate checked |

The spec's 5–7 weeks did not include the docs site, six million-unit scenarios, the UI audit or an independent review.
Expect M6 to take longer; that is a working estimate, not a measured one.

## Open questions for the maintainer

1. **Niche.** The spec recommends tech/AI launches. Confirm, or pick your own build-in-public community.
2. **Jurisdiction and collateral.** Confirm non-transferable points only, no prizes, and an India-first geo-disclaimer.
   Decide whether to block access from any region.
3. **Arbiter.** Who signs the multisig, how many signers, and the threshold. Can the arbiter also propose?
4. **Moderation.** UI-and-API listing only, or an on-chain approver role on `createMarket`?
5. **LP provision.** Drop it, or decide on a mechanism (LS-LMSR or CPMM markets)?
6. **INVALID refund rule.** The last traded price, or an equal split?
7. **Hosting.** The spec says Cloudflare Pages + Docker Compose + Neon; the standard says same-origin on the droplet +
   systemd. Neon (which cannot carry `LISTEN/NOTIFY` over the pooler) or Postgres on the droplet? One droplet shared
   with other apps, or one for this product?
8. **RPC.** A paid Base RPC provider or your own node? Public RPC limits are unverified.
9. **Design identity.** Palette, type and shape for this product (options with screenshots for you to choose).
10. **Gasless onboarding.** Accept a CDP (or other) paymaster account as a dependency, or defer it?
11. **Reuse of Gnosis code (LGPL-3.0):** allowed or not?
12. **Static analysis and review.** Which tools, and who does the independent review?
13. **UMA stretch.** Is a mock-oracle-only testnet integration worth building?
