# Decisions

Trade-offs and decisions, D-001 onward. Each entry says what was chosen and why; a
superseded decision is marked, never rewritten.

## D-001 — Base: the Backend Platform starter template

The repository begins as a copy of the Backend Platform's copy-and-own starter template —
the bounded HTTP layer, the three-role PostgreSQL split with its protections manifest,
the accounts kit, releases, restore drills, and the CI + evidence kit — renamed for this
product. The commit it came from is in `TEMPLATE_ORIGIN`; later template changes arrive
only as reviewed diffs. Nothing shares a package, service, login or database with the
template's repository or any sibling product.

## D-002 — Port band 63100-63199

Every port this repository binds on a shared development machine stays inside
63100–63199: the server on 63150, the development PostgreSQL on 63132, the template's
other defaults shifted into the band. `scripts/check-ports.sh` fails on a literal outside
the band, and the gate proves it can fail. Rationale: Linux's ephemeral range ends at
60999, so CI and a second checkout never collide.

## D-003 — Stack

Rust backend on Axum, SQLx and tokio (the template's stack); SvelteKit + TypeScript
(strict) for the web UI once the maintainer chooses this product's design system — no
`web/` product code before that. Solidity + Foundry only for on-chain code, in
`contracts/`. Everything else follows `docs/END_GOAL.md`.

## D-004 — LMSR fixed point: the stable binary form and its bounds

`LMSRMarket` evaluates `C(q) = max(q) + b·ln(1 + e^(-d))`, `d = |q0 − q1|/b`, with PRBMath
v4.2.4 (`SD59x18.exp` on a non-positive argument, `UD60x18.ln` on `[1, 2]`), so no
intermediate exceeds `max(q) + b` and `exp` never overflows. Bounds, in WAD: `1e18 ≤ b ≤
1e30`, `q ≤ 1e30`; `e^(-d)` is 0 for `d ≥ 42` (PRBMath returns 0 below −41.45; at 42 the
laggard's price is below 1e-18). The leading price is `1e18 −` the lagging price, so prices
sum to exactly 1e18. Every buy is charged `ΔC + costError()` rounded up and every sell paid
`ΔC − costError()` rounded down, `costError = ⌈32·b/1e18⌉ + 1` wei: the differential sweep
against `lmsr-ref` (8 values of b, two traders, buys and sells, d = 0 to 42 on both sides in
b/4 steps with q1 ≠ 0: 4,048 states) measured a worst 14 wei per 1e18 of b, and asserts at most
16, so 32 stays at least twice the measured error. A trader can
never profit from rounding; the cost is at most 2·costError per round trip.

## D-005 — `lmsr-ref`: an 80-digit reference, called by forge through FFI

`crates/lmsr-ref` computes the same market in 80-decimal fixed point (`num-bigint`
0.5.1, `num-traits` 0.2.19; no float) and returns floor/ceil brackets of every exact
value. `lmsr-ref replay` takes at most 512 operations (`LIMIT(replay-ops)`) and answers
with ABI words; `vm.ffi` is enabled only in forge's `diff` profile, which calls nothing else.
`shares_for_spend` steps back over a boundary case at most 8 times, then answers 0, as the
Solidity side does (`LIMIT(step-back)`), so no quote can loop.

## D-006 — Foundry and the Solidity libraries

Foundry v1.10.0, installed by `scripts/install-foundry.sh` against SHA-256 values recorded in
the script (no `foundryup`, no `curl | sh`). Libraries are git submodules at release tags:
forge-std v1.17.0, OpenZeppelin Contracts v5.6.1 (ERC-20, ERC-1155, AccessControl,
ReentrancyGuard, Math), PRBMath v4.2.4 (exp/ln). Points and outcome shares are
not transferable by token calls: only a registered market moves them, into or out of itself
(value can still move between accounts through a market: D-007).

## D-007 — Points move between accounts through markets; points confer no rank

Points are not transferable by token calls; value can move between accounts through any
market, which is why points confer no rank. Any AMM lets two accounts do it: from
`q = (0, 0)`, A buys D of one outcome, B buys D of the other, A sells, B sells; B gains
about `D − 2·b·ln 2` of A's points and the pair pays the pool only the rounding margins
(264 wei at `b = 1e18`, `D = 1e6` points, independent of D, so raising the minimum b does not
help). `contracts/test/unit/ValueMoves.t.sol` pins the size and cost of that move. Nothing
— prize, rank, privilege, faucet allowance — is ever keyed to a points balance or points
profit (`THREATS.md` T-1).

## D-008 — The leaderboard ranks Brier skill; the faucet caps per identity

The leaderboard (M5) ranks forecasting skill by a proper scoring rule, the Brier score, on
each account's resolved positions — never points balance or points profit, which D-007
makes transferable. Faucet caps per identity (LT-6) are a requirement on the faucet
milestone (M5): sybil accounts farming the faucet and passing points to one account is the
attack they bound.

## D-009 — Tracked to M2 from the M1 review

- **One admin key** (`THREATS.md` T-2): `PointsToken.pull(from, …)` needs no consent from
  `from`, so `DEFAULT_ADMIN_ROLE` granting `MARKET_ROLE` to an EOA drains every balance, and
  `OutcomeToken.registerMarket` cannot be undone. M2: the factory is the only grantor; the
  admin role is renounced or held behind a timelocked multisig.
- **Clones and immutables** (T-3): EIP-1167 clones share the implementation's immutables
  (`b`, `closeTime`, `resolver`). M2 deploys each market in full with CREATE2, or uses a
  guarded initializer with a locked implementation.
- **Locked points** (T-4): no cancel, INVALID or no-proposer timeout; leftover subsidy is
  never returned; a lost resolver key locks redemption; the resolver may trade. M2 adds
  cancel/INVALID/timeout, subsidy return, and a resolver that cannot trade its own market.
