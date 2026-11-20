#!/usr/bin/env bash
# The contracts gate: forge fmt --check, the build, the unit, fuzz and invariant tests
# (10,000 runs per fuzz property), then the M1 differential fuzz, which drives the Solidity
# market and lmsr-ref (built here, release) with the same trades through vm.ffi. FFI is on
# only in that profile, and only lmsr-ref is called. LT-5 at full scale is scripts/lt5.sh.
#
#   scripts/check-contracts.sh
#
# Needs forge (scripts/install-foundry.sh target/tools/bin), the contracts/lib submodules
# (git submodule update --init --recursive) and the pinned Rust toolchain.
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ $# -eq 0 ] || { echo "check-contracts.sh: takes no arguments (see --help)" >&2; exit 2; }
cd "$(dirname "$0")/.."
[ -d target/tools/bin ] && PATH="$PWD/target/tools/bin:$PATH"
command -v forge >/dev/null || { echo "check-contracts.sh: forge not found: scripts/install-foundry.sh target/tools/bin" >&2; exit 2; }
[ -f contracts/lib/prb-math/src/UD60x18.sol ] || { echo "check-contracts.sh: contracts/lib is empty: git submodule update --init --recursive" >&2; exit 2; }
forge --version | head -1 | grep -q 'forge Version: 1.10.0' || { echo "check-contracts.sh: forge is not the pinned 1.10.0" >&2; exit 2; }
cargo build --release --locked -p lmsr-ref
export LMSR_REF="$PWD/target/release/lmsr-ref"
cd contracts
forge fmt --check
forge build --sizes
forge test
FOUNDRY_PROFILE=diff forge test -vv
