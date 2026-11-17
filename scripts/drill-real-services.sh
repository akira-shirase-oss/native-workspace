#!/usr/bin/env bash
# Drill `disconnect-restart` against real, scratch instances of the paired services.
#
# Builds Service Monitor and Durable Runner from their repositories' `main` (git archive
# into a temp dir — the repositories themselves are only read), starts them on loopback
# ports in 60400-60499 with every byte of data under one mktemp dir in /tmp, and runs
# RealServiceDrillTests, which asks for each SIGKILL; the script kills both services,
# waits a random 4-9 s, restarts them on the same data, and says so. The paired service is
# never a load target here: this is a functional drill. In cycle 1, while both services
# are down, an impostor (Python's http.server, a different program) binds Service Monitor's
# port for a few seconds: the app, pinned to monitor-server (D-015), must send it nothing.
# The result goes to
# perf/results/drills/ with machine, toolchain, commits and timings. Everything started is
# stopped and the temp dir removed on exit, pass or fail.
#
#   scripts/drill-real-services.sh [--cycles N] [--smon-bin PATH --smon-rev SHA]
#                                  [--durable-bin PATH --durable-rev SHA]
# (prebuilt binaries must say which commit they were built from; it is recorded)
#
# Needs: rustup (Rust 1.99.1, per those repositories), openssl, curl, Xcode.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
products="${NW_PRODUCTS_DIR:-$here/../../products}"
cycles=3
smon_bin=""
durable_bin=""
smon_rev=""
durable_rev=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cycles) cycles="$2"; shift 2 ;;
    --smon-bin) smon_bin="$2"; shift 2 ;;
    --durable-bin) durable_bin="$2"; shift 2 ;;
    --smon-rev) smon_rev="$2"; shift 2 ;;
    --durable-rev) durable_rev="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done

SMON_PORT=60410
DEAD_PORT=60411   # nothing listens: a monitor that fails honestly
DURABLE_PORT=60420
for port in $SMON_PORT $DEAD_PORT $DURABLE_PORT; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN > /dev/null 2>&1; then
    echo "drill: port $port is in use; refusing to start" >&2
    exit 1
  fi
done

work="$(mktemp -d /tmp/nw-real-drill.XXXXXX)"
smon_pid=""
durable_pid=""
test_pid=""
impostor_pid=""
cleanup() {
  for pid in $test_pid $smon_pid $durable_pid $impostor_pid; do
    [ -n "$pid" ] && kill "$pid" 2> /dev/null || true
  done
  wait 2> /dev/null || true
  # Anything of ours still listening (only binaries started from this drill's paths).
  for port in $SMON_PORT $DURABLE_PORT; do
    for pid in $(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2> /dev/null); do
      case "$(ps -o command= -p "$pid")" in
        *"$smon_bin"* | *"$durable_bin"*) kill "$pid" 2> /dev/null || true ;;
      esac
    done
  done
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/control" "$work/smon" "$work/durable"
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

if { [ -n "$smon_bin" ] && [ -z "$smon_rev" ]; } || { [ -n "$durable_bin" ] && [ -z "$durable_rev" ]; }; then
  echo "drill: a prebuilt binary needs the commit it was built from (--smon-rev/--durable-rev)" >&2
  exit 2
fi
[ -z "$smon_bin" ] && smon_rev="$(git -C "$products/service-monitor" rev-parse main)"
[ -z "$durable_bin" ] && durable_rev="$(git -C "$products/durable-runner" rev-parse main)"
if [ -z "$smon_bin" ] || [ -z "$durable_bin" ]; then
  export PATH="$(brew --prefix rustup)/bin:$PATH"
  unset CARGO_TARGET_DIR
  if [ -z "$smon_bin" ]; then
    echo "drill: building Service Monitor main ($smon_rev)"
    mkdir -p "$work/src/smon"
    git -C "$products/service-monitor" archive main | tar -x -C "$work/src/smon"
    (cd "$work/src/smon" && CARGO_TARGET_DIR="$work/target-smon" cargo build -q --release -p monitor-server)
    smon_bin="$work/target-smon/release/monitor-server"
  fi
  if [ -z "$durable_bin" ]; then
    echo "drill: building Durable Runner main ($durable_rev)"
    mkdir -p "$work/src/durable"
    git -C "$products/durable-runner" archive main | tar -x -C "$work/src/durable"
    (cd "$work/src/durable" && CARGO_TARGET_DIR="$work/target-durable" cargo build -q --release -p durable-server)
    durable_bin="$work/target-durable/release/durable-server"
  fi
fi

# Secrets: generated here, passed only through the environment, never printed.
SMON_TOKEN="$(openssl rand -hex 32)"
DURABLE_KEY="$(openssl rand -hex 32)"

start_smon() {
  # `exec` so $! is the server itself: SIGKILL must reach the service, not a wrapper.
  (cd "$work/smon" && exec env -i PATH="$PATH" HOME="$work/smon" \
    SMON_PROFILE=lab SMON_ADMIN_TOKEN="$SMON_TOKEN" SMON_LISTEN="127.0.0.1:$SMON_PORT" \
    SMON_DATABASE_URL="sqlite:$work/smon/monitor.db" SMON_STATUS_DIR="$work/smon/status" \
    "$smon_bin" >> "$work/smon/server.log" 2>&1) &
  smon_pid=$!
}
start_durable() {
  (cd "$work/durable" && exec env -i PATH="$PATH" HOME="$work/durable" DURABLE_API_KEY="$DURABLE_KEY" \
    "$durable_bin" --journal "$work/durable/journal" --listen "127.0.0.1:$DURABLE_PORT" $durable_reads \
    --handler "fails=http://127.0.0.1:$DEAD_PORT/step" --step-timeout-ms 500 \
    >> "$work/durable/server.log" 2>&1) &
  durable_pid=$!
}
wait_http() { # url
  for _ in $(seq 1 200); do
    curl -fsS -o /dev/null --max-time 1 "$1" 2> /dev/null && return 0
    sleep 0.05
  done
  echo "drill: $1 never answered; server logs:" >&2
  tail -n 20 "$work/smon/server.log" "$work/durable/server.log" >&2 2> /dev/null || true
  return 1
}
kill_hard() { # pid port
  kill -9 "$1" 2> /dev/null || true
  wait "$1" 2> /dev/null || true
  # Prove it: the port must be closed before the drill says "killed".
  for _ in $(seq 1 100); do
    lsof -nP -iTCP:"$2" -sTCP:LISTEN > /dev/null 2>&1 || return 0
    sleep 0.02
  done
  echo "drill: port $2 still listening after SIGKILL" >&2
  exit 1
}

# Newer Durable Runner builds require a key for reads unless they run with --open-reads,
# which answers only on loopback (their D-037). The app reads without a credential.
durable_reads=""
if "$durable_bin" --help 2> /dev/null | grep -q -- '--open-reads'; then durable_reads="--open-reads"; fi

# Newer Service Monitor builds create a store only with `--init` (their D-015); older
# ones create it on first start. Ask the binary which kind it is.
if "$smon_bin" --help 2> /dev/null | grep -q -- '--init'; then
  (cd "$work/smon" && env -i PATH="$PATH" HOME="$work/smon" \
    SMON_PROFILE=lab SMON_ADMIN_TOKEN="$SMON_TOKEN" SMON_LISTEN="127.0.0.1:$SMON_PORT" \
    SMON_DATABASE_URL="sqlite:$work/smon/monitor.db" SMON_STATUS_DIR="$work/smon/status" \
    "$smon_bin" --init >> "$work/smon/server.log" 2>&1)
fi
start_smon
start_durable
wait_http "http://127.0.0.1:$SMON_PORT/livez"
wait_http "http://127.0.0.1:$DURABLE_PORT/health"

# Seed: the drill's driver may write; the app under test never does.
add_monitor() { # name url
  curl -fsS -o /dev/null --max-time 5 -X POST -H "Authorization: Bearer $SMON_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"name\":\"$1\",\"url\":\"$2\",\"interval_s\":15,\"timeout_s\":2,\"failures_to_open\":1}" \
    "http://127.0.0.1:$SMON_PORT/api/monitors"
}
add_monitor self-livez "http://127.0.0.1:$SMON_PORT/livez"
add_monitor durable-health "http://127.0.0.1:$DURABLE_PORT/health"
add_monitor nothing-listening "http://127.0.0.1:$DEAD_PORT/"
for n in 1 2 3 4 5; do
  curl -fsS -o /dev/null --max-time 5 -X POST -H "Authorization: Bearer $DURABLE_KEY" \
    -H 'Content-Type: application/json' \
    --data "{\"op_key\":\"drill-$n\",\"spec\":{\"version\":1,\"steps\":[{\"name\":\"s\",\"handler\":\"fails\"}],\"input_b64\":\"\"}}" \
    "http://127.0.0.1:$DURABLE_PORT/jobs"
done

echo "drill: services up (smon pid $smon_pid, durable pid $durable_pid); building tests"
swift build -q --build-tests
NW_REAL_DRILL_DIR="$work/control" NW_REAL_DRILL_CYCLES="$cycles" \
  NW_SMON_URL="http://127.0.0.1:$SMON_PORT" NW_SMON_TOKEN="$SMON_TOKEN" \
  NW_SMON_EXPECT_EXECUTABLE="$smon_bin" \
  NW_DURABLE_URL="http://127.0.0.1:$DURABLE_PORT" \
  swift test --skip-build --filter RealServiceDrillTests > "$work/test.log" 2>&1 &
test_pid=$!

for cycle in $(seq 1 "$cycles"); do
  while [ ! -f "$work/control/want-kill-$cycle" ]; do
    if ! kill -0 "$test_pid" 2> /dev/null; then break 2; fi
    sleep 0.05
  done
  kill_hard "$smon_pid" "$SMON_PORT"
  kill_hard "$durable_pid" "$DURABLE_PORT"
  now > "$work/control/killed-$cycle.tmp" && mv "$work/control/killed-$cycle.tmp" "$work/control/killed-$cycle"
  echo "drill: cycle $cycle: both services killed (SIGKILL)"
  if [ "$cycle" -eq 1 ]; then
    # The impostor: another program (Python's http.server, which logs every request it
    # gets) on Service Monitor's port. NWListener could not rebind the port this soon after
    # a SIGKILL (EADDRINUSE); http.server sets SO_REUSEADDR, as the real service does.
    mkdir -p "$work/impostor-root"
    (cd "$work/impostor-root" && exec python3 -I -u -m http.server "$SMON_PORT" --bind 127.0.0.1) \
      > "$work/impostor.log" 2>&1 &
    impostor_pid=$!
    for _ in $(seq 1 150); do
      grep -q 'Serving HTTP' "$work/impostor.log" 2> /dev/null && break
      sleep 0.1
    done
    if grep -q 'Serving HTTP' "$work/impostor.log"; then
      sleep 5
      kill -TERM "$impostor_pid" 2> /dev/null || true
      wait "$impostor_pid" 2> /dev/null || true
      echo "$(grep -c '"GET \|"POST \|"HEAD ' "$work/impostor.log" || true) requests" \
        > "$work/control/impostor.tmp"
    else
      echo "the impostor did not start" > "$work/control/impostor.tmp"
      kill -TERM "$impostor_pid" 2> /dev/null || true
      wait "$impostor_pid" 2> /dev/null || true
    fi
    impostor_pid=""
    mv "$work/control/impostor.tmp" "$work/control/impostor"
    echo "drill: impostor saw: $(cat "$work/control/impostor")"
    sed 's/^/drill: impostor log: /' "$work/impostor.log"
  fi
  sleep "$(perl -e 'printf "%.2f", 4 + rand(5)')"
  # The down window ends when the restart begins: a poll may succeed before
  # the "restarted" marker below is written.
  now > "$work/control/restarting-$cycle.tmp" && mv "$work/control/restarting-$cycle.tmp" "$work/control/restarting-$cycle"
  start_smon
  start_durable
  wait_http "http://127.0.0.1:$SMON_PORT/livez"
  wait_http "http://127.0.0.1:$DURABLE_PORT/health"
  now > "$work/control/restarted-$cycle.tmp" && mv "$work/control/restarted-$cycle.tmp" "$work/control/restarted-$cycle"
  echo "drill: cycle $cycle: both services restarted on the same data"
done

status=0
wait "$test_pid" || status=$?
test_pid=""
grep -E "error:|passed \(|failed \(|skipped" "$work/test.log" || true

mkdir -p perf/results/drills
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
commit="$(git rev-parse HEAD)"
[ -n "$(git status --porcelain)" ] && commit="$commit+dirty"
out="perf/results/drills/real-disconnect-restart-$stamp-${commit:0:7}.json"
python3 -I - "$work/control/result.json" "$out" "$status" "$commit" "$smon_rev" "$durable_rev" <<'EOF'
import json, os, platform, subprocess, sys
src, dst, status, commit, smon, durable = sys.argv[1:7]
try:
    result = json.load(open(src))
except Exception as error:
    result = {"error": f"no result written: {error}"}
def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
result.update({
    "pass": status == "0" and "error" not in result,
    "test_exit_status": int(status),
    "commit": commit,
    "service_monitor_main": smon,
    "durable_runner_main": durable,
    "machine": {
        "model": run("sysctl", "-n", "hw.model"),
        "cpu": run("sysctl", "-n", "machdep.cpu.brand_string"),
        "cores": int(run("sysctl", "-n", "hw.ncpu")),
        "macos": run("sw_vers", "-productVersion"),
        "load_average_at_end": os.getloadavg(),
    },
    "toolchain": run("xcodebuild", "-version").replace("\n", " "),
})
json.dump(result, open(dst, "w"), indent=2, sort_keys=True)
print(f"drill: wrote {dst} (pass={result['pass']})")
EOF
exit "$status"
