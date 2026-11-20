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
against `lmsr-ref` measured a worst 14 wei per 1e18 of b, so 32 is twice that. A trader can
never profit from rounding; the cost is at most 2·costError per round trip.

## D-005 — `lmsr-ref`: an 80-digit reference, called by forge through FFI

`crates/lmsr-ref` computes the same market in 80-decimal fixed point (`num-bigint`
0.5.1, `num-traits` 0.2.19; no float) and returns floor/ceil brackets of every exact
value. `lmsr-ref replay` takes at most 512 operations (`LIMIT(replay-ops)`) and answers
with ABI words; `vm.ffi` is enabled only in forge's `diff` profile, which calls nothing else.

## D-006 — Foundry and the Solidity libraries

Foundry v1.10.0, installed by `scripts/install-foundry.sh` against SHA-256 values recorded in
the script (no `foundryup`, no `curl | sh`). Libraries are git submodules at release tags:
forge-std v1.17.0, OpenZeppelin Contracts v5.6.1 (ERC-20, ERC-1155, AccessControl,
ReentrancyGuard, Math), PRBMath v4.2.4 (exp/ln). Points and outcome shares are
non-transferable at the token: only a registered market moves them, into or out of itself.
