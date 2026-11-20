#!/usr/bin/env bash
# LT-5 contract-invariants (docs/END_GOAL.md): the Foundry invariant campaign at full scale,
# 4,000 runs x depth 256 = 1,024,000 handler calls, against the thresholds written in
# perf/scenarios/lt5.md before the first run. It writes the result: the machine (CPU, cores,
# memory, OS: never the host's name), the commit and whether the tree was dirty, the load
# average before and after, the calls, reverts and invariant outcomes. A miss fails the run
# and is kept, never re-run until green.
#
#   scripts/lt5.sh                       full scale, into perf/results
#   RUNS=64 DEPTH=32 scripts/lt5.sh      a plumbing probe, into target/perf
#
# Needs forge (scripts/install-foundry.sh) and jq.
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ $# -eq 0 ] || { echo "lt5.sh: unknown argument $1 (see --help)" >&2; exit 2; }
cd "$(dirname "$0")/.."
export PATH="$PWD/target/tools/bin:$PATH"
command -v forge >/dev/null || { echo "lt5.sh: forge not found: run scripts/install-foundry.sh" >&2; exit 2; }

mode=full; outdir=perf/results
runs=4000; depth=256
if [ -n "${RUNS:-}${DEPTH:-}" ]; then
  runs="${RUNS:-4000}"; depth="${DEPTH:-256}"; mode="probe-${runs}x${depth}"; outdir=target/perf
fi
case "$runs$depth" in *[!0-9]*) echo "lt5.sh: RUNS and DEPTH are integers" >&2; exit 2 ;; esac
min_calls=1000000

work="$(mktemp -d "${TMPDIR:-/tmp}/predict-lt5.XXXXXX")"
trap 'rm -rf "$work"' EXIT
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
load_before="$(uptime | sed 's/.*load averages*: *//')"
start="$(date +%s)"
set +e
(cd contracts && FOUNDRY_PROFILE=lt5 FOUNDRY_INVARIANT_RUNS="$runs" FOUNDRY_INVARIANT_DEPTH="$depth" \
  forge test --match-contract LMSRInvariants) >"$work/out.txt" 2>&1
forge_status=$?
set -e
seconds=$(( $(date +%s) - start ))
load_after="$(uptime | sed 's/.*load averages*: *//')"

summary="$(grep -oE 'invariants \(runs: [0-9]+, calls: [0-9]+, reverts: [0-9]+\)' "$work/out.txt" | tail -1 || true)"
if [ -z "$summary" ]; then
  echo "lt5.sh: forge produced no campaign summary (status $forge_status); its output:" >&2
  tail -40 "$work/out.txt" >&2
  exit 1
fi
read -r got_runs calls reverts < <(sed -E 's/.*runs: ([0-9]+), calls: ([0-9]+), reverts: ([0-9]+).*/\1 \2 \3/' <<<"$summary")
passed="$(grep -cE '^\[PASS\] invariant_' "$work/out.txt" || true)"
broken="$(grep -cE '^\[FAIL.*\] invariant_' "$work/out.txt" || true)"
invariants="$(grep -oE '^\[(PASS|FAIL)[^]]*\] invariant_[a-z0-9_]+' "$work/out.txt" | sed -E 's/^\[(PASS|FAIL)[^]]*\] /\1 /' | jq -R . | jq -s .)"

ok=true
if [ "$mode" = full ] && [ "$calls" -lt "$min_calls" ]; then ok=false; fi
[ "$broken" -eq 0 ] && [ "$forge_status" -eq 0 ] || ok=false
[ $(( reverts * 100 )) -le "$calls" ] || ok=false

if [ "$(uname -s)" = Darwin ]; then
  cpu="$(sysctl -n machdep.cpu.brand_string)"; cores="$(sysctl -n hw.ncpu)"
  mem_gb="$(( $(sysctl -n hw.memsize) / 1073741824 ))"; os="macOS $(sw_vers -productVersion)"
else
  cpu="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"; cores="$(nproc)"
  mem_gb="$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1048576 ))"; os="$(uname -sr)"
fi
commit="$(git rev-parse HEAD)"
dirty=false; git diff --quiet HEAD -- . ':!perf/results' || dirty=true
mkdir -p "$outdir"
out="$outdir/${stamp}-lt5-${mode}.json"
jq -n --arg mode "$mode" --arg stamp "$stamp" --arg commit "$commit" --argjson dirty "$dirty" \
  --arg cpu "$cpu" --arg cores "$cores" --arg mem_gb "$mem_gb" --arg os "$os" \
  --arg load_before "$load_before" --arg load_after "$load_after" \
  --arg forge "$(forge --version | head -1)" \
  --argjson runs "$got_runs" --argjson depth "$depth" --argjson calls "$calls" --argjson reverts "$reverts" \
  --argjson passed "$passed" --argjson broken "$broken" --argjson invariants "$invariants" \
  --argjson seconds "$seconds" --argjson ok "$ok" --argjson min_calls "$min_calls" '
  { scenario: "lt5-contract-invariants", mode: $mode, started_utc: $stamp, commit: $commit, tree_dirty: $dirty,
    machine: { cpu: $cpu, cores: ($cores|tonumber), memory_gb: ($mem_gb|tonumber), os: $os,
               load_average_before: $load_before, load_average_after: $load_after },
    tool: $forge,
    thresholds: { min_handler_calls: $min_calls, max_broken_invariants: 0, max_revert_percent: 1 },
    thresholds_passed: $ok,
    runs: $runs, depth: $depth, handler_calls: $calls, reverts: $reverts,
    invariants_passed: $passed, invariants_broken: $broken, invariants: $invariants,
    wall_seconds: $seconds }' >"$out"
echo "result: $out"
scripts/check-results.sh "$out" >/dev/null
jq '{mode, commit, thresholds_passed, runs, depth, handler_calls, reverts, invariants_passed, invariants_broken, wall_seconds}' "$out"
[ "$ok" = true ] || { grep -E '^\[FAIL' "$work/out.txt" >&2 || true; exit 1; }
