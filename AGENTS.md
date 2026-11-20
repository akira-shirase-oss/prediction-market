# Niche Prediction Market — agent instructions

A niche prediction market dApp on Base: every market's price is always quoted, its
collateral always covers every possible payout, and every resolution can be traced from
proposal to final outcome.

Contract: `docs/END_GOAL.md` (what done means, scope, the required failure cases and
their drills, the ship gate); the verified facts it rests on are in
`docs/KNOWLEDGE.md`. Status: **base setup only — nothing of the product is built yet**;
the running code is the renamed Backend Platform starter template.

## Read first

1. `docs/END_GOAL.md` — the contract: scope, failure cases, ship gate.
2. `docs/KNOWLEDGE.md` — verified facts and sources; re-check versions at M0.
3. `docs/DECISIONS.md` — the decisions so far (base, port band, stack).
4. `docs/ROADMAP.md` — M0 onward; a status cell says *Done* only with named tests and
   evidence.

## Non-negotiables

1. **Performance and reliability come first.** Bounded queues and bodies, deadlines on
   every I/O await, idempotent writes, crash-safe state, no blocking on async workers.
2. **Evidence over claims.** Load runs are at least 1,000,000 units and run on CI-hosted
   runners, not a laptop; results carry machine, commit and load; misses are kept, never
   re-run until green.
3. **Every feature ships** regression tests + a fault-fixture path + a load scenario in
   the same change; every fixed bug gets a test that fails without it.
4. **The port band is 63100-63199.** Server 63150, development PostgreSQL 63132;
   `scripts/check-ports.sh` fails on a literal outside the band.
5. **Money is exact.** Collateral covers every payout; play-money points are
   non-transferable — see the legal constraint in the README.
6. **No secrets or payloads in logs.** Typed errors (`thiserror`) in libraries, `anyhow`
   at binary boundaries; no `unwrap`/`expect` on external input.

## Verification

`scripts/check.sh` runs what CI runs — run it before every push. Local stack:
`scripts/stack.sh up` (PostgreSQL on 127.0.0.1:63132); the server binds
127.0.0.1:63150. Its credentials are public development values.

## The web UI

The design system is the maintainer's choice and has not been made. `web/` holds only a
stub: do not start a SvelteKit app until it is decided.
