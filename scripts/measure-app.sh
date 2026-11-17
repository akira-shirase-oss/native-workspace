#!/usr/bin/env bash
# Measure the running app's main-thread responsiveness under load.
#
# Starts nw-fixture-server on 127.0.0.1:60450 (20 monitors x 50 slots/s = 1,000 events/s,
# plus a 10,000-event burst every 5 s — fixture burst-10k; the paired service is never the
# load target, D-022), launches the release app against it in measurement mode
# (NW_MEASURE_SECONDS): the app's own watchdog pings the main thread every 10 ms, and the
# app writes a report and quits. With --instruments the app runs under `xctrace` with the
# Time Profiler template plus the Hangs instrument, and the hang table is exported.
#
#   scripts/measure-app.sh [--seconds 60] [--label NAME] [--instruments] [--stall] [--idle] [--busy]
#
#   --stall  the "before" of the UI-stall drill: draw events with the SwiftUI List that
#            stalled the main thread (NW_EVENT_LIST=swiftui-list)
#   --idle   no event load (the fixture emits nothing): idle CPU and memory
#   --busy   allow a run when the 1-minute load average is 6 or more; the result says so
#   --keep-trace DIR  copy the .trace bundle there (bundles are not committed: too large)
# The window opens without taking focus. Results: perf/results/app/.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

seconds=60
label="load"
instruments=0
stall=0
idle=0
busy_ok=0
keep_trace=""
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) seconds="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --instruments) instruments=1; shift ;;
    --stall) stall=1; shift ;;
    --idle) idle=1; shift ;;
    --busy) busy_ok=1; shift ;;
    --keep-trace) keep_trace="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done

PORT=60450
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN > /dev/null 2>&1; then
  echo "measure: port $PORT is in use" >&2
  exit 1
fi
load="$(sysctl -n vm.loadavg | awk '{print $2}')"
machine_note="quiet machine (1-min load $load at start)"
if awk -v l="$load" 'BEGIN { exit !(l >= 6) }'; then
  if [ "$busy_ok" -ne 1 ]; then
    echo "measure: 1-minute load average is $load (>= 6); re-run when quiet or pass --busy" >&2
    exit 3
  fi
  machine_note="BUSY machine (1-min load $load at start): development smoke observation"
fi

swift build -q -c release --product NativeWorkspace
swift build -q -c release --product nw-fixture-server
bin="$(swift build -c release --show-bin-path)"
work="$(mktemp -d /tmp/nw-measure.XXXXXX)"
fixture_pid=""
cleanup() {
  [ -n "$fixture_pid" ] && kill "$fixture_pid" 2> /dev/null || true
  wait 2> /dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# The fixture's token: generated, environment only, never printed.
export NW_FIXTURE_TOKEN="$(openssl rand -hex 32)"
if [ "$idle" -eq 1 ]; then
  fixture_args=(--port "$PORT" --monitors 20 --slot-interval 100000)
else
  fixture_args=(--port "$PORT" --monitors 20 --slot-interval 0.02 --burst-every 5 --burst-size 10000)
fi
"$bin/nw-fixture-server" "${fixture_args[@]}" > "$work/fixture.log" 2>&1 &
fixture_pid=$!
for _ in $(seq 1 100); do
  grep -q listening "$work/fixture.log" 2> /dev/null && break
  sleep 0.05
done

export NW_SMON_URL="http://127.0.0.1:$PORT"
export NW_SMON_TOKEN="$NW_FIXTURE_TOKEN"
export NW_SMON_CHECKS_PER_MONITOR=500
export NW_POLL_DEADLINE_S="${NW_POLL_DEADLINE_S:-3}"
export NW_STORE_DIR="$work/store"
export NW_MEASURE_SECONDS="$seconds"
export NW_MEASURE_OUT="$work/report.json"
if [ "$stall" -eq 1 ]; then export NW_EVENT_LIST=swiftui-list; else unset NW_EVENT_LIST; fi

status=0
if [ "$instruments" -eq 1 ]; then
  xcrun xctrace record --template 'Time Profiler' --instrument Hangs --no-prompt \
    --time-limit "$((seconds + 30))s" --output "$work/app.trace" \
    --launch -- "$bin/NativeWorkspace" > "$work/xctrace.log" 2>&1 || status=$?
  xcrun xctrace export --input "$work/app.trace" --toc > "$work/toc.xml" 2>> "$work/xctrace.log" || true
  schema="$(grep -Eo 'schema="[^"]*hang[^"]*"' "$work/toc.xml" | head -1 | cut -d'"' -f2 || true)"
  if [ -n "$schema" ]; then
    xcrun xctrace export --input "$work/app.trace" \
      --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]" \
      > "$work/hangs.xml" 2>> "$work/xctrace.log" || true
  fi
else
  "$bin/NativeWorkspace" > "$work/app.log" 2>&1 || status=$?
fi
kill "$fixture_pid" 2> /dev/null || true
wait "$fixture_pid" 2> /dev/null || true
fixture_pid=""
if [ -n "$keep_trace" ] && [ -d "$work/app.trace" ]; then
  mkdir -p "$keep_trace"
  rm -rf "$keep_trace/app.trace"
  cp -R "$work/app.trace" "$keep_trace/app.trace"
  echo "measure: kept the trace at $keep_trace/app.trace"
fi

mkdir -p perf/results/app
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
commit="$(git rev-parse HEAD)"
[ -n "$(git status --porcelain)" ] && commit="$commit+dirty"
out="perf/results/app/measure-$label-$stamp-${commit:0:7}.json"
if [ -f "$work/hangs.xml" ]; then cp "$work/hangs.xml" "${out%.json}.instruments-hangs.xml"; fi
python3 -I - "$work" "$out" "$commit" "$machine_note" "$stall" "$idle" "$instruments" "$status" <<'EOF'
import json, os, re, subprocess, sys
work, out, commit, note, stall, idle, instruments, status = sys.argv[1:9]
def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
try:
    report = json.load(open(os.path.join(work, "report.json")))
except Exception as error:
    report = {"error": f"the app wrote no report: {error}"}
result = {
    "scenario": "running app, fixture load" if idle == "0" else "running app, idle",
    "fixture": "20 monitors x 50 slots/s = 1,000 events/s, 10,000-event burst every 5 s"
    if idle == "0" else "20 monitors, no events",
    "event_list": "swiftui-list (the drill's before)" if stall == "1" else "table (AppKit)",
    "commit": commit,
    "machine_note": note,
    "toolchain": run("xcodebuild", "-version").replace("\n", " "),
    "macos": run("sw_vers", "-productVersion"),
    "load_average_at_end": os.getloadavg(),
    "app_exit_status": int(status),
    "app_report": report,
}
hangs = os.path.join(work, "hangs.xml")
if instruments == "1":
    if os.path.exists(hangs):
        text = open(hangs, encoding="utf-8", errors="replace").read()
        rows = re.findall(r"<row>(.*?)</row>", text, re.S)
        durations = []
        for row in rows:
            m = re.search(r'<duration[^>]*fmt="([^"]*)"[^>]*>(\d+)</duration>', row)
            if m:
                durations.append(int(m.group(2)) / 1e6)  # ns -> ms
        result["instruments"] = {
            "template": "Time Profiler + Hangs",
            "hang_rows": len(rows),
            "hang_durations_ms": sorted(durations, reverse=True)[:50],
            "hangs_ge_250ms": sum(1 for d in durations if d >= 250),
            "exported_table": os.path.basename(out).replace(".json", ".instruments-hangs.xml"),
        }
    else:
        log = open(os.path.join(work, "xctrace.log")).read()[-2000:]
        result["instruments"] = {"error": "no hang table exported", "xctrace_log_tail": log}
json.dump(result, open(out, "w"), indent=2, sort_keys=True)
w = report.get("watchdog", {})
print(f"measure: wrote {out}")
print(f"  watchdog: pings {w.get('pings')}, hangs>=250ms {w.get('hangs')}, "
      f"stall p99 {w.get('latencyMs', {}).get('p99')} ms, max {w.get('latencyMs', {}).get('max')} ms")
if "instruments" in result:
    print(f"  instruments: {result['instruments'].get('hang_rows', 'n/a')} hang rows, "
          f"{result['instruments'].get('hangs_ge_250ms', 'n/a')} >= 250 ms")
EOF
exit "$status"
