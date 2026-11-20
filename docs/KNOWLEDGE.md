# Niche Prediction Market: verified domain knowledge

Checked on 2026-11-20 against the v2.0 spec (02_Niche_Prediction_Market_dApp, dated 2026-11-20). Every fact has a
source. "Observed" means I read it myself from a public Base RPC (`https://sepolia.base.org`,
`https://mainnet.base.org`) on 2026-11-20. **UNVERIFIED** means I could not confirm it. "The spec says" marks numbers
taken from the spec without confirmation. None of this is legal advice.

## 1. Market maker maths

### LMSR: the formulas the builder needs

- Cost function `C(q) = b·ln(Σ_i exp(q_i/b))`. Price `p_i = exp(q_i/b) / Σ_j exp(q_j/b)` (a softmax, so the prices sum
  to exactly 1 before rounding). The market maker's worst-case loss is `b·ln(n)` for `n` outcomes. The spec states all
  three correctly. Source: R. Hanson, *Logarithmic Market Scoring Rules for Modular Combinatorial Information
  Aggregation* (2007), https://mason.gmu.edu/~rhanson/mktscore.pdf.
- Buying `Δ` shares of outcome `i` costs `C(q + Δ·e_i) − C(q)`. Selling returns `C(q) − C(q − Δ·e_i)`.
- **Binary closed form** (derived from the above; cheap to evaluate on-chain): with current YES price `p`, buying `Δ`
  YES costs `b·ln(1 − p + p·e^(Δ/b))`, and the shares a spend `x` buys are `Δ = b·ln((e^(x/b) − (1 − p)) / p)`.
- **Numerically stable form.** Subtract the largest quantity before exponentiating:
  `C(q) = m + b·ln(Σ exp((q_i − m)/b))`, with `m = max q_i`. Every exponent is then ≤ 0. Gnosis's on-chain LMSR does
  exactly this; its comment says a naive version overflows "since anything above a bit over 133*ONE supplied to exp will
  explode" (https://github.com/gnosis/conditional-tokens-market-makers/blob/master/contracts/LMSRMarketMaker.sol).

**Worked example** (computed here; use it in `MECHANISM.md`): `b = 100`, binary, starting at `p = 0.5`.

| Action | Result |
|---|---|
| Subsidy the creator must lock | `100·ln 2 = 69.31` points (the maximum loss) |
| Buy 50 YES | costs 28.09; YES price moves 0.500 → 0.622 |
| Sell those 50 YES straight back | returns 28.09 (path independence; rounding must make this strictly less) |
| Spend 10 at `p = 0.5` | buys 19.09 YES |
| Same 50-share buy with `b = 20` | costs 37.71; price jumps to 0.924 |

**Solvency follows from the subsidy.** Starting from `q = 0`, the collateral held is the subsidy plus all net trade
costs: `b·ln n + C(q) − C(0) = C(q)`, because `C(0) = b·ln n`. And `C(q) ≥ max_i q_i`, because the sum of exponentials
is at least its largest term. So the maximum possible payout (the largest outstanding outcome quantity) is always
covered, provided the pool deposits at least `b·ln n` (rounded up) and every rounding goes in the pool's favour. This
is the spec's first invariant, and it is provable, not just fuzzable.

### LMSR failure modes the spec only partly covers

1. **Overflow and underflow.** PRBMath's `exp` reverts above `x = 133.084258667509499440` and returns exactly zero below
   `−41.446531673892822322` (SD59x18; `EXP_MAX_INPUT` and `uEXP_MIN_THRESHOLD` in
   https://github.com/PaulRBerg/prb-math/blob/main/src/sd59x18/Constants.sol). With the stable form there is no overflow,
   but an outcome more than about `41·b` shares behind the leader gets price 0, and the shares-for-spend formula divides
   by `p`. Guard it; test it.
2. **Rounding extraction.** Round costs up and returns down (the spec says this). Gnosis rounds its net cost up with
   `EstimationMode.UpperBound` (same file). The property to fuzz: any buy/sell sequence returning the trader to the
   starting position never yields a profit, fees excluded.
3. **Liquidity insensitivity.** `b` is fixed in advance, so the same trade moves price equally in thin and thick
   markets, and choosing `b` "is viewed as a black art". Othman, Sandholm, Pennock and Reeves proposed LS-LMSR to fix
   this (*A Practical Liquidity-Sensitive Automated Market Maker*, EC 2010;
   https://www.cs.cmu.edu/~./theorylunch/pastSemesterIndices/20100922.html). For niche markets a fixed small `b` is
   acceptable, but the UI must show price impact.
4. **The spec's P1 "add/remove liquidity, LP fee share" does not fit a fixed-`b` LMSR.** LMSR has no natural LP share.
   In Gnosis's implementation `changeFunding` is `onlyOwner` and allowed only `atStage(Stage.Paused)`
   (https://github.com/gnosis/conditional-tokens-market-makers/blob/master/contracts/MarketMaker.sol). Either drop LP
   provision from LMSR markets or design a separate mechanism (LS-LMSR, or CPMM markets). This is a spec contradiction.
5. **The event happens before `closeTime`.** If a launch ships early, anyone who knows can buy the winning side until
   close and take up to the full `b·ln n` subsidy. The spec has no early-close path. Production markets need a
   resolver-callable early close (inference from the maths above, not from a source).
6. **No INVALID outcome.** Ambiguous or unresolvable markets need an outcome that refunds by a stated rule. The spec's
   lifecycle has only the listed outcomes (spec gap).
7. **Thin-market front-running.** `maxCost`/`minReturn` bound a victim's loss but do not prevent sandwiching; small `b`
   makes it cheap (the spec accepts this risk).

### Fixed-point libraries

- **PRBMath** is current at v4.2.4 (released 2026-11-13), MIT licence (https://github.com/PaulRBerg/prb-math/releases,
  npm `@prb/math`). Install with `forge install PaulRBerg/prb-math@release-v4`. The spec's choice is sound.
- **rust_decimal** 1.43.0 (2026-09-02, MIT, https://crates.io/crates/rust_decimal). `exp`/`ln` need the `maths`
  feature, and the docs say `exp` "stops calculating when it is within tolerance of roughly 0.0000002"
  (https://docs.rs/rust_decimal/latest/rust_decimal/trait.MathematicalOps.html). Its maximum value is about 7.92e28, so
  `exp(x)` overflows above `x ≈ 66.54`, roughly half PRBMath's limit.
  **Correction to the spec:** a reference implementation accurate to about 2e-7 cannot catch 18-decimal rounding bugs
  in the Solidity. Use `exp_with_tolerance` with a much tighter tolerance, or an arbitrary-precision type, for the
  differential oracle. Set the agreement tolerance from measured error, and keep the stable form in both languages.

### CPMM / FPMM and order books

- Gnosis ships both an LMSR and a Fixed Product Market Maker (`FixedProductMarketMaker.sol`) over the Conditional
  Tokens Framework. **Both repositories are LGPL-3.0** and have had no pushes since January 2023 (GitHub API:
  `gnosis/conditional-tokens-market-makers`, `gnosis/conditional-tokens-contracts`). Copying their code into an
  MIT/Apache repository is a licensing question for the maintainer.
- The spec says CPMM was "used by early Polymarket/Omen". **UNVERIFIED**: I found no primary source dating Polymarket's
  move off its AMM. Polymarket's current docs describe a "hybrid-decentralized" CLOB with off-chain matching,
  on-chain non-custodial settlement and ERC-1155 outcome tokens from the Gnosis CTF on Polygon
  (https://docs.polymarket.com/developers/CLOB).
- A CLOB is rightly out of scope for the MVP (the spec says so).

## 2. Outcome tokens and contracts

- ERC-1155 positions with a complete set minted and burned for 1 collateral is the Gnosis CTF design, which Polymarket
  also uses (same Polymarket docs). OpenZeppelin Contracts is at 5.6.1 (MIT, npm, 2026-02-27) and provides `ERC1155`
  and `Clones`. Foundry is at v1.10.0 (2026-11-19, https://github.com/foundry-rs/foundry/releases). Differential tests
  through `vm.ffi` need `ffi = true` in `foundry.toml`. That flag runs arbitrary commands, so CI should enable it only in
  the profile that runs those tests.

## 3. Resolution

### The spec's MVP resolver

Bonded propose, a 24-hour dispute window (the spec's number), and a multisig arbiter. This is a sound and honest MVP if
the trust assumption is written down. Missing pieces to specify: an INVALID outcome, early close, a timeout when no one
proposes, and who may propose (anyone, or a role).

### UMA Optimistic Oracle V3: the current state

- **OOv3 is current and deployed on Base Sepolia** at `0x0F7fC5E6482f096380db6158f978167b57388deE`, alongside a
  `MockOracleAncillary` (UMA's deployment registry,
  https://github.com/UMAprotocol/protocol/blob/master/packages/core/networks/84532.json). On Base mainnet, OOv3 is at
  `0x2aBf1Bd76655de80eDB3086114315Eec75AF500c`, with an `OracleSpoke` that relays disputes to the DVM on Ethereum
  (`8453.json`).
- **Observed on Base Sepolia:** `defaultLiveness` = 7200 s (2 hours), `burnedBondPercentage` = 0.5e18 (50%),
  `defaultIdentifier` = `ASSERT_TRUTH`, and `defaultCurrency` = a "TestnetERC20" (18 decimals) with a minimum bond of 0.
- **Mechanics, from the contract source**
  (https://github.com/UMAprotocol/protocol/blob/master/packages/core/contracts/optimistic-oracle-v3/implementation/OptimisticOracleV3.sol):
  - `assertTruth(claim, asserter, callbackRecipient, escalationManager, liveness, currency, bond, identifier, domainId)`
    requires a whitelisted currency ("Unsupported currency") and `bond >= getMinimumBond(currency)`.
  - `getMinimumBond = finalFee·1e18 / burnedBondPercentage`, which is twice the final fee at 50%.
  - On a dispute, `burnedBondPercentage` of the bond goes to the UMA Store. UMA's docs say "when a disputer is correct,
    they receive half of the proposer's bond" (https://docs.uma.xyz/llms-full.txt).
  - Custom escalation managers can change who may assert or dispute and how disputes resolve.
  - **Consequence:** the spec's own points token cannot be a UMA bond currency unless UMA governance whitelists it. On
    testnet, use the TestnetERC20.
- **DVM timeline (mainnet only):** a 24-hour commit phase and a 24-hour reveal phase; "the DVM vote resolves the case
  within 2-4 days"; the vote rolls to the next round if participation thresholds are not met (same UMA docs).
- **Correction to the spec's stretch goal:** on testnets, disputes go to a mock oracle and are settled by a manual
  `pushPrice`. UMA's sandbox docs say "anyone can push desired test price through this mock oracle contract", and the
  first push wins
  (https://docs.uma.xyz/developers/optimistic-oracle-v3/sandboxed-oracle-environment). A Base Sepolia "UMA
  integration" therefore shows the integration code, not UMA's security. Present it that way.
- **Known governance attack.** In March 2025 a roughly $7M Polymarket market ("Ukraine agrees to Trump mineral deal
  before April?") resolved YES after a UMA vote that users attributed to one holder voting about 5M UMA from three
  accounts. Polymarket called it unprecedented and did not refund
  (https://www.theblock.co/post/348171; https://cointelegraph.com/news/polymarket-trump-ukraine-bet-whale-governance-attack).
  These are allegations reported by the press, not an investigation's findings.
- **Managed OOv2.** After UMIP-189 (approved 2025-08-06), Polymarket moved to the Managed Optimistic Oracle V2, where
  proposals can be limited to whitelisted proposers. Disputes stay open to anyone
  (https://www.theblock.co/post/366507/polymarket-uma-oracle-update;
  https://docs.uma.xyz/developers/managedoptimisticoraclev2/default-proposer-whitelist). The lesson for the write-up:
  even the largest optimistic-oracle user added permissioning.

## 4. The chain: Base Sepolia in November 2026

- Chain ID 84532 (observed, `eth_chainId`).
- **Correction to the spec and any 2-second-block assumption:** Denim activated on Base Sepolia on 2026-10-21 and on
  Base Mainnet on 2026-11-05. It "replaced Flashblocks with a complete canonical block every 200ms", and the
  Flashblocks WebSocket endpoints were shut down on 2026-11-19 (https://docs.base.org/base-chain/flashblocks/faq).
  - Observed: 5,000 blocks in 1,000 s on both networks (0.2 s per block). That is 432,000 blocks a day.
  - `block.timestamp` is whole seconds, so about five consecutive blocks share a timestamp. Order events by
    `(block_number, log_index)`, never by time.
- **Finality:** OP Stack heads are `latest` (unsafe), `safe` (batch data on Ethereum) and `finalized` (that Ethereum
  data finalized). The Sequencer "can reorganize these blocks until their data lands on Ethereum"
  (https://docs.optimism.io/op-stack/transactions/transaction-finality). Observed on Base Sepolia: `safe` lagged
  `latest` by 317 blocks (63 s) and `finalized` by 4,861 blocks (972 s). Use the `safe`/`finalized` tags rather than
  the spec's "N confirmations". Show `latest` data in the UI as provisional.
- **Chain halts happen.** Base mainnet stopped producing blocks twice in late June 2026 (about 116 and 20 minutes)
  because of a sequencer bug (https://www.theblock.co/post/406409/base-suffers-second-mainnet-stall-in-two-days). The
  indexer and UI must distinguish "chain stalled" from "indexer stalled".
- Test collateral: Circle's faucet gives 20 USDC per address per chain every 2 hours, Base Sepolia included
  (https://faucet.circle.com/). For legal reasons (section 8), the spec's own non-transferable points token is the
  better collateral.

## 5. Indexing: custom Rust indexer or The Graph

| Option | State on 2026-11-20 | Fit |
|---|---|---|
| Custom indexer on `alloy` | alloy 2.6.1 (2026-11-16, MIT OR Apache-2.0, MSRV 1.94.1, https://crates.io/crates/alloy) | The spec's choice. Full control of reorgs, checkpoints and the Postgres schema; it is the portfolio piece |
| rindexer (Rust, YAML or Rust project) | v1.0.0 released 2026-11-15, MIT (https://github.com/joshstevens19/rindexer) | Prior art to study, or a fallback |
| The Graph Subgraph Studio | Free tier 100,000 queries a month, then $2 per 100,000 (https://thegraph.com/pricing.md, updated 2026-05-28); graph-node is Rust, Apache-2.0 | A hosted dependency and GraphQL instead of the API you own. Base Sepolia support **UNVERIFIED** (the supported-networks page did not show testnets) |
| Ponder (TypeScript) / Envio HyperIndex | Both active (GitHub, Nov 2026) | Off-stack (not Rust) |

**Reorg handling for the custom indexer.** Store `(block_number, block_hash, parent_hash)` for each processed block.
On every poll, confirm the stored head hash still matches the chain; on a mismatch, walk back to the common ancestor,
delete derived rows above it inside one transaction, and replay. With 200 ms blocks, size `eth_getLogs` ranges by
block count and the provider's limits. Public RPC limits are **UNVERIFIED**, so plan for a paid RPC or your own node.
Reorg tests can run on Anvil (Foundry). Whether Anvil offers a reorg RPC method in v1.10 is **UNVERIFIED**; recorded
fixtures with a forked branch are the safe default.

## 6. Serving reads and live prices

- **SSE through Cloudflare.** The default proxy read timeout is 100 s
  (https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-524/). Send
  a server heartbeat well inside that window.
- **Neon's pooler** is PgBouncer in transaction mode. It supports protocol-level prepared statements (PgBouncer 1.22,
  up to 1,000 per connection) but not session features such as `LISTEN/NOTIFY`
  (https://neon.com/docs/connect/connection-pooling). Do not fan out price updates through Postgres `NOTIFY` over the
  pooled URL. SQLx is at 0.9.1 (2026-11-18). Whether SQLx's statement cache behaves under Neon's 1,000-statement cap is
  **UNVERIFIED**.
- The workspace rule is `sslmode=verify-full` for Neon (workspace AGENTS.md).
- OG images: `resvg` 0.50.0 (Apache-2.0 OR MIT, 2026-11-11).

## 7. Gasless onboarding (spec P1)

ERC-4337 EntryPoint v0.8 added native EIP-7702 support
(https://erc4337.mirror.xyz/TQ5ctZl5Lx2cernjq7FvrNDS222WT_w9wS3GuHu1g6U). The CDP Paymaster supports Base Sepolia
(https://docs.cdp.coinbase.com/paymaster/faqs). Which EntryPoint version CDP supports on Base Sepolia today is
**UNVERIFIED**. Either way, this adds a third-party bundler/paymaster dependency and an account, so it stays P1.

## 8. Regulatory constraints on a public demo (not legal advice)

- **India.** The Promotion and Regulation of Online Gaming Act, 2025, with its 2026 Rules, came into force on
  2026-05-01 (https://www.business-standard.com/industry/news/govt-notifies-online-gaming-rules-effective-may-1-126042201415_1.html).
  - It prohibits "online money games", meaning games played "by paying fees, depositing money or other stakes in
    expectation of winning".
  - "Other stakes" covers "anything recognised as equivalent or convertible to money and includes credits, coins,
    token or objects".
  - Offering carries up to three years' imprisonment or a ₹1 crore fine; advertising carries up to two years or ₹50
    lakh (https://www.barandbench.com/law-firms/view-point/game-over-rules-reset-by-indias-online-gaming-act).
  - **Constraints:** collateral must not be convertible to money (no transfers, no market, no redemption outside the
    app); no prizes of value for leaderboards; no paid market creation. A tradable testnet token is weaker than
    non-transferable points.
- **United States.** Real-money event contracts sit under the CFTC. Polymarket paid a $1.4M penalty in 2022 and
  returned only through a CFTC Amended Order of Designation (2025-11-25) after buying QCEX
  (https://www.theblock.co/post/380384/homegrown-nyc-startup-polymarket-resume-us-operations-cftc-reversal).
  Manifold ended its sweepstakes cash layer in 2025 and returned to play money only
  (https://manifoldmarkets.notion.site/Investor-update-3-6-25-1ac54492ea7a8022aaf1ed2cd188663d).
  **Constraint:** no money in, no money out, and no prize of value.
- Other jurisdictions: **UNVERIFIED**. Keep the geo-disclaimer the spec asks for.
- **The spec's revenue ideas** ("trading fees, paid market creation") are incompatible with points-only in India. The
  play-money internal-forecasting path is the only one consistent with these constraints.

## 9. Scoring

The Brier score for binary forecasts is the mean of `(p − outcome)²`. Always forecasting 0.5 scores 0.25, and uniformly
random forecasts score about 0.333 in expectation (computed here; definition at
https://en.wikipedia.org/wiki/Brier_score).

**Correction:** the spec's "better than 0.25 (better than random)" really means "better than a constant 50%
forecast". The threshold is right; the wording is not.

## 10. Corrections to the spec, in brief

1. Base now has 200 ms blocks, not 2 s. This changes indexer sizing, time ordering and load numbers.
2. A UMA dispute on Base Sepolia goes to a mock oracle anyone can answer. The stretch goal shows integration only.
3. The P1 LP feature conflicts with fixed-`b` LMSR.
4. rust_decimal's `exp` tolerance (about 2e-7) is too coarse for an 18-decimal differential oracle.
5. Missing paths: early close, an INVALID outcome, and a no-proposer timeout.
6. Collateral must be non-convertible points under India's 2025 Act, and the fee and paid-creation revenue lines are
   out.
7. Use `safe`/`finalized` tags, not N confirmations.
8. The Gnosis reference code is LGPL-3.0.
