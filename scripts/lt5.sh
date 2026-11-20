#!/usr/bin/env bash
# LT-5 contract-invariants (docs/END_GOAL.md): two Foundry invariant campaigns at full scale,
# 8,000 runs x depth 256 each, against the thresholds written in perf/scenarios/lt5.md. The
# trading campaign (LMSRInvariants: no market ever closes) must execute at least 1,000,000
# trades, counted by the handler's ghost variable, not by forge's call total, and at least
# that many when scaled down to forge's call total (the handler also sees calls forge's summary
# does not count, so the conservative figure must hold too); the resolution
# campaign (LMSRInvariantsResolution: staggered closes, resolve and redeem) runs beside it. It
# writes the result: the machine (CPU, cores, memory, OS: never the host's name), the commit
# and whether the tree was dirty, the load average before and after, each campaign's calls,
# executed trades, reverts and invariant outcomes. A miss fails the run and is kept, never
# re-run until green.
#
#   scripts/lt5.sh                       full scale, into perf/results
#   RUNS=64 DEPTH=32 scripts/lt5.sh      a plumbing probe, into target/perf
#
# Needs forge 1.10.0 (scripts/install-foundry.sh) and jq.
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ $# -eq 0 ] || { echo "lt5.sh: unknown argument $1 (see --help)" >&2; exit 2; }
cd "$(dirname "$0")/.."
export PATH="$PWD/target/tools/bin:$PATH"
command -v forge >/dev/null || { echo "lt5.sh: forge not found: run scripts/install-foundry.sh" >&2; exit 2; }
forge --version | head -1 | grep -q 'forge Version: 1.10.0' || {
  echo "lt5.sh: forge is not the pinned 1.10.0: run scripts/install-foundry.sh" >&2
  exit 2
}

mode=full; outdir=perf/results
runs=8000; depth=256
if [ -n "${RUNS:-}${DEPTH:-}" ]; then
  runs="${RUNS:-8000}"; depth="${DEPTH:-256}"; mode="probe-${runs}x${depth}"; outdir=target/perf
fi
case "$runs$depth" in *[!0-9]*) echo "lt5.sh: RUNS and DEPTH are integers" >&2; exit 2 ;; esac
min_trades=1000000

work="$(mktemp -d "${TMPDIR:-/tmp}/predict-lt5.XXXXXX")"
trap 'rm -rf "$work"' EXIT
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
# The handler's ghost counts land here, one file per run (foundry.toml's lt5 fs_permissions).
ghost="$PWD/target/lt5/$stamp"
rm -rf "$ghost"; mkdir -p "$ghost"
load_before="$(uptime | sed 's/.*load averages*: *//')"
start="$(date +%s)"
set +e
(cd contracts && LT5_GHOST_DIR="$ghost" FOUNDRY_PROFILE=lt5 FOUNDRY_INVARIANT_RUNS="$runs" \
  FOUNDRY_INVARIANT_DEPTH="$depth" forge test) >"$work/out.txt" 2>&1
forge_status=$?
set -e
seconds=$(( $(date +%s) - start ))
load_after="$(uptime | sed 's/.*load averages*: *//')"

ok=true
# campaign <contract> <ghost name>: one JSON object (it runs in a subshell; the thresholds are
# applied to the objects below).
campaign() {
  local contract="$1" name="$2" summary got_runs calls reverts lines trades handler_calls held resolutions
  summary="$(grep -oE "^ *$contract invariants \(runs: [0-9]+, calls: [0-9]+, reverts: [0-9]+\)" "$work/out.txt" | tail -1 || true)"
  if [ -z "$summary" ]; then
    echo "lt5.sh: forge produced no $contract summary (status $forge_status); its output:" >&2
    tail -40 "$work/out.txt" >&2
    exit 1
  fi
  read -r got_runs calls reverts < <(sed -E 's/.*runs: ([0-9]+), calls: ([0-9]+), reverts: ([0-9]+).*/\1 \2 \3/' <<<"$summary")
  # One file per run, named by a fingerprint of the run's end state.
  read -r lines trades handler_calls held resolutions < <(find "$ghost" -name "$name-*.txt" -exec cat {} + |
    awk '{n++; t+=$1; c+=$2; h+=$3; r+=$4} END {printf "%d %d %d %d %d\n", n, t, c, h, r}')
  # Two runs that end in the same state share a file, so a few runs may go unreported: that
  # only lowers the trade count, never raises it.
  [ "$lines" -ge "$got_runs" ] || echo "lt5.sh: $contract: $lines distinct end states in $got_runs runs" >&2
  jq -n --argjson runs "$got_runs" --argjson depth "$depth" --argjson calls "$calls" --argjson reverts "$reverts" \
    --argjson reported "$lines" --argjson trades "$trades" --argjson handler_calls "$handler_calls" \
    --argjson held "$held" --argjson resolutions "$resolutions" \
    '{ runs: $runs, depth: $depth, forge_calls: $calls, reverts: $reverts, runs_reported: $reported,
       handler_calls: $handler_calls, executed_trades: $trades, held_share_transfer_attempts: $held,
       resolutions: $resolutions,
       executed_trades_scaled_to_forge_calls:
         (if $handler_calls == 0 then 0 else ($trades * $calls / $handler_calls | floor) end) }'
}
trading="$(campaign LMSRInvariants trading)"
resolution="$(campaign LMSRInvariantsResolution resolution)"
jq -e --argjson min "$min_trades" --arg mode "$mode" \
  '.[0] as $t | .[1] as $r
   | ($t.runs_reported * 100 >= $t.runs * 99 and $r.runs_reported * 100 >= $r.runs * 99)
     and ($t.reverts * 100 <= $t.forge_calls and $r.reverts * 100 <= $r.forge_calls)
     and ($t.held_share_transfer_attempts > 0 and $r.held_share_transfer_attempts > 0)
     and $r.resolutions > 0
     and ($mode != "full" or ($t.executed_trades >= $min and $t.executed_trades_scaled_to_forge_calls >= $min))' <<<"[$trading, $resolution]" >/dev/null || ok=false
passed="$(grep -cE '^\[PASS\] invariant_' "$work/out.txt" || true)"
broken="$(grep -cE '^\[FAIL.*\] invariant_' "$work/out.txt" || true)"
invariants="$(grep -oE '^\[(PASS|FAIL)[^]]*\] invariant_[a-z0-9_]+' "$work/out.txt" | sed -E 's/^\[(PASS|FAIL)[^]]*\] /\1 /' | jq -R . | jq -s .)"
[ "$broken" -eq 0 ] && [ "$forge_status" -eq 0 ] || ok=false

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
  --argjson trading "$trading" --argjson resolution "$resolution" \
  --argjson passed "$passed" --argjson broken "$broken" --argjson invariants "$invariants" \
  --argjson seconds "$seconds" --argjson ok "$ok" --argjson min_trades "$min_trades" '
  { scenario: "lt5-contract-invariants", mode: $mode, started_utc: $stamp, commit: $commit, tree_dirty: $dirty,
    machine: { cpu: $cpu, cores: ($cores|tonumber), memory_gb: ($mem_gb|tonumber), os: $os,
               load_average_before: $load_before, load_average_after: $load_after },
    tool: $forge,
    thresholds: { min_executed_trades_trading_campaign: $min_trades,
                  min_executed_trades_scaled_to_forge_calls: $min_trades, max_broken_invariants: 0,
                  max_revert_percent_per_campaign: 1, min_runs_reported_percent: 99,
                  min_held_share_transfer_attempts: 1, min_resolutions: 1 },
    thresholds_passed: $ok,
    executed_trades: $trading.executed_trades,
    campaigns: { trading: $trading, resolution: $resolution },
    invariants_passed: $passed, invariants_broken: $broken, invariants: $invariants,
    wall_seconds: $seconds }' >"$out"
echo "$out" >target/lt5/last-result
echo "result: $out"
scripts/check-results.sh "$out" >/dev/null
jq '{mode, commit, thresholds_passed, executed_trades, campaigns, invariants_passed, invariants_broken, wall_seconds}' "$out"
[ "$ok" = true ] || { grep -E '^\[FAIL' "$work/out.txt" >&2 || true; exit 1; }
