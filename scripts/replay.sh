#!/usr/bin/env bash
# The headless package replay (ROADMAP §N0 load scenario).
#   scripts/replay.sh --smoke        30,000 events, debug build; the ledger must hold (CI)
#   scripts/replay.sh --full         1,000,000 events, release build, result committed under
#                                    perf/results/ with machine, toolchain and commit
#   scripts/replay.sh --full --busy  run anyway on a busy machine; the result says so
# A full run needs a quiet machine: it refuses when the 1-minute load average is 6 or more
# (12 cores shared with other builds) unless --busy is given. Misses are kept, never rerun
# until green: the result file is written whether the run passed or failed.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

mode="${1:---smoke}"
busy_ok="${2:-}"

case "$mode" in
  --smoke)
    out="$(mktemp "${TMPDIR:-/tmp}/nw-replay-smoke.XXXXXX")"
    trap 'rm -f "$out"' EXIT
    status=0
    swift run -q nw-replay --smoke > "$out" || status=$?
    grep -E '"(pass|dropped|gap_count_sum|duplicates_refused|acknowledged_events|hangs_ge_250ms)"' "$out" || true
    if [ "$status" -ne 0 ]; then
      cat "$out"
      echo "replay smoke FAILED (exit $status)" >&2
    fi
    exit "$status"
    ;;
  --full) ;;
  *)
    echo "usage: scripts/replay.sh --smoke | --full [--busy]" >&2
    exit 2
    ;;
esac

load="$(sysctl -n vm.loadavg | awk '{print $2}')"
note="quiet machine (1-min load $load at start)"
if awk -v l="$load" 'BEGIN { exit !(l >= 6) }'; then
  if [ "$busy_ok" != "--busy" ]; then
    echo "replay: 1-minute load average is $load (>= 6); the full run is owed. Re-run when quiet," >&2
    echo "        or pass --busy to record a smoke observation on a busy machine." >&2
    exit 3
  fi
  note="BUSY machine (1-min load $load at start): development smoke observation, not a baseline"
fi

commit="$(git rev-parse HEAD)"
if [ -n "$(git status --porcelain)" ]; then commit="$commit+dirty"; fi
toolchain="$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//'); $(swift --version 2>&1 | head -1)"
swift build -q -c release --product nw-replay
mkdir -p perf/results
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="perf/results/replay-1m-$stamp-${commit:0:7}.json"
status=0
NW_TOOLCHAIN="$toolchain" "$(swift build -c release --show-bin-path)/nw-replay" \
  --events 1000000 --commit "$commit" --note "$note" --out "$out" > /dev/null || status=$?
echo "replay: wrote $out (exit $status)"
grep -E '"(pass|wall_seconds|throughput_acknowledged_per_s|p99|hangs_ge_250ms|footprint_bytes)"' "$out" || true
exit "$status"
