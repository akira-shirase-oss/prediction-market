#!/usr/bin/env bash
# Every contract protection is proven by a test that fails when the protection is removed:
# the Solidity counterpart of scripts/prove-limits.sh.
#
# Each protection in contracts/src carries a marker, `// GUARD(name)`, on the comment line
# just above the line that enforces it. For every marker this script deletes that line in a
# scratch copy of contracts/ and runs the one test that proves it, which must then FAIL as a
# test (a build error is not a proof). The tests are first run unmutated and must pass. A
# marker without a mutation below, or a mutation whose marker is gone, fails the script, so a
# new protection cannot be added without its proof.
#
#   scripts/prove-contracts.sh [--out FILE]   (FILE: a JSON record; never names the machine)
#
# Needs forge 1.10.0 (scripts/install-foundry.sh target/tools/bin) and the contracts/lib
# submodules. The scratch copy is deleted at the end.
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;; esac
cd "$(dirname "$0")/.."
here="$PWD"
out=""
case "${1:-}" in
  "") ;;
  --out) out="${2:?--out needs a file}" ;;
  *) echo "prove-contracts.sh: unknown argument $1 (see --help)" >&2; exit 2 ;;
esac
[ -d target/tools/bin ] && PATH="$PWD/target/tools/bin:$PATH"
command -v forge >/dev/null || { echo "prove-contracts.sh: forge not found: scripts/install-foundry.sh target/tools/bin" >&2; exit 2; }
# Matched in the shell: a pipe into grep -q can die of SIGPIPE under pipefail.
forge_version="$(forge --version)"
[[ "$forge_version" == "forge Version: 1.10.0"* ]] || { echo "prove-contracts.sh: forge is not the pinned 1.10.0" >&2; exit 2; }
[ -f contracts/lib/prb-math/src/UD60x18.sol ] || { echo "prove-contracts.sh: contracts/lib is empty: git submodule update --init --recursive" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/predict-prove-contracts.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir "$work/contracts"
cp -R contracts/src contracts/test contracts/foundry.toml "$work/contracts/"
ln -s "$here/contracts/lib" "$work/contracts/lib"

# name|file (under contracts/src)|test that must fail without it
mutations=(
  "redeem-burn|LMSRMarket.sol|test_redeeming_shares_you_do_not_hold_is_refused"
  "sell-burn|LMSRMarket.sol|test_selling_shares_you_do_not_hold_is_refused"
  "resolver|LMSRMarket.sol|test_resolving_by_anyone_else_is_refused"
  "resolve-once|LMSRMarket.sol|test_resolving_twice_is_refused"
  "points-update|PointsToken.sol|test_points_cannot_be_transferred_between_accounts"
  "outcome-update|OutcomeToken.sol|test_outcome_shares_cannot_be_transferred"
  "outcome-mint|OutcomeToken.sol|test_only_a_registered_market_mints_outcome_shares"
  "outcome-burn|OutcomeToken.sol|test_only_a_registered_market_burns_outcome_shares"
)

found="$(grep -rhoE 'GUARD\([a-z-]+\)' contracts/src | sed 's/GUARD(\(.*\))/\1/' | sort)"
defined="$(printf '%s\n' "${mutations[@]}" | cut -d'|' -f1 | sort)"
if [ "$found" != "$defined" ]; then
  echo "error: markers and mutations differ (each marker exactly once):" >&2
  diff <(echo "$found") <(echo "$defined") >&2 || true
  exit 1
fi

# The line under the marker, deleted; it must be code, not another comment.
mutate() { # file marker
  python3 -I - "$work/contracts/src/$1" "$2" <<'PY'
import sys
path, marker = sys.argv[1:]
lines = open(path).read().split("\n")
hits = [i for i, line in enumerate(lines) if line.strip() == f"// GUARD({marker})"]
if len(hits) != 1:
    sys.exit(f"GUARD({marker}) is not on a line of its own exactly once")
target = hits[0] + 1
if target >= len(lines) or not lines[target].strip() or lines[target].strip().startswith("//"):
    sys.exit(f"GUARD({marker}) is not directly above a line of code")
del lines[target]
open(path, "w").write("\n".join(lines))
PY
}

tests="$(printf '%s\n' "${mutations[@]}" | cut -d'|' -f3 | paste -sd'|' -)"
set +e
baseline="$(cd "$work/contracts" && forge test --match-test "^($tests)\\(\\)$" 2>&1)"
status=$?
set -e
passed="$(grep -cE '^\[PASS\] ' <<<"$baseline" || true)"
if [ "$status" -ne 0 ] || [ "$passed" -ne "${#mutations[@]}" ]; then
  echo "error: unmutated, the proving tests must all pass ($passed of ${#mutations[@]} did):" >&2
  tail -30 <<<"$baseline" >&2
  exit 1
fi

failures=0
results=()
for row in "${mutations[@]}"; do
  IFS='|' read -r name file test <<<"$row"
  cp "$here/contracts/src/$file" "$work/contracts/src/$file"
  mutate "$file" "$name"
  started=$(date +%s)
  set +e
  output="$(cd "$work/contracts" && forge test --match-test "^${test}\\(\\)$" 2>&1)"
  status=$?
  set -e
  seconds=$(( $(date +%s) - started ))
  cp "$here/contracts/src/$file" "$work/contracts/src/$file"
  if [ "$status" -ne 0 ] && grep -qE "^\[FAIL.*\] ${test}\(\) \(gas" <<<"$output"; then
    verdict=proven
    printf '  proven   %-16s %s fails without it (%ss)\n' "$name" "$test" "$seconds"
  elif [ "$status" -ne 0 ]; then
    verdict=broken
    failures=$((failures + 1))
    printf '  BROKEN   %-16s the mutation did not build or the test did not run:\n%s\n' "$name" "$(tail -20 <<<"$output")"
  else
    verdict=unproven
    failures=$((failures + 1))
    printf '  UNPROVEN %-16s %s still passes with the protection deleted\n' "$name" "$test"
  fi
  results+=("$(jq -n --arg name "$name" --arg file "contracts/src/$file" --arg test "$test" \
    --arg verdict "$verdict" --argjson seconds "$seconds" \
    '{guard: $name, file: $file, test: $test, verdict: $verdict, seconds: $seconds}')")
done

if [ -n "$out" ]; then
  mkdir -p "$(dirname "$out")"
  printf '%s\n' "${results[@]}" | jq -s --arg commit "$(git rev-parse HEAD)" --arg tool "${forge_version%%$'\n'*}" \
    '{scenario: "prove-contracts", commit: $commit, tool: $tool, mutations: .,
      proven: (map(select(.verdict == "proven")) | length), total: length}' >"$out"
fi
[ "$failures" -eq 0 ] || { echo "prove-contracts.sh: $failures of ${#mutations[@]} protections are not proven" >&2; exit 1; }
echo "prove-contracts.sh: all ${#mutations[@]} protections proven"
