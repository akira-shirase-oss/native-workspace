# Results

Every file records the machine, toolchain and commit it ran on (AGENTS §8). Numbers from
this Mac are development observations, never capacity. Misses are kept: a failed or
broken run stays here with its explanation; nothing is rerun until green and the failure
deleted.

Machine for every run below unless a file says otherwise: Apple M2 Pro (Mac14,10),
12 cores, 32 GB, macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2. The machine was
shared with other builds all session (1-minute load average 23–94); files say so.

## Drills — `drills/`

| File | What | Result |
|---|---|---|
| `package-disconnect-restart-1000-*.json` | Package-level drill, fixture server killed and restarted at 1,000 random points, two simulated app restarts (`DisconnectRestartDrillTests`, `NW_DRILL_ITERATIONS=1000`) | see the file; summarized in `docs/ROADMAP.md` §N0 status |
| `real-disconnect-restart-20261117T013356Z-64c10e4.json` | Real scratch Service Monitor (`659e468`) and Durable Runner (`3da25ef`) on 127.0.0.1:60410/60420, data under `/tmp`, SIGKILL + restart × 5, the shell's `AppModel` with the contract timings (2 s polls, 1 s grace, backoff 1 s → 30 s) | **pass**: stale 0.01–1.69 s after each kill (bound 3 s), live again 1.8–3.0 s after each restart without re-pairing, 0 live samples while down, 0 green while not live, 30 events acknowledged, 0 lost, 0 duplicate rows, also after reopening the store from disk. Commit is `64c10e4+dirty` (the slice-3 working tree, before it was committed) |
| `real-disconnect-restart-20261117T012912Z-64c10e4.driver-bug.json` | First real run | **fail, driver bug**: the driver's `kill -9` hit the wrapping subshell, so the services never died; the test correctly reported 226 live samples "while down". Fixed with `exec` and a port-closed check after every kill |
| `real-disconnect-restart-20261117T013102Z-64c10e4.window-bug.json` | Second real run | **fail, 3 live samples in the down window.** The window ended at the driver's "restarted" marker, written only after both services answered, so a poll could land after the real restart and inside the window. The window now ends when the restart begins (`restarting-N`) and the samples between restart-begin and the marker are recorded (0 in the passing run). The explanation is consistent with the data but was not proven by a reproduction |

## Replay — `replay-1m-*.json`

`scripts/replay.sh --full`: 1,000,000 events through the bounded queue (10,000), the
on-disk store (`F_FULLFSYNC` per batch, 50,000 retained) and the main-actor event list
(10,000 rows), offered at 20,000 events/s in 10,000-event bursts, every 10th burst an
overload of 20,000 that must drop, every 20th preceded by 1,000 re-offered duplicates.
The full run refuses to start at a 1-minute load average of 6 or more; until a quiet run
exists the result is **owed** (only CI's 30,000-event smoke has run).

## App — `app/`

`scripts/measure-app.sh`: the release app against `nw-fixture-server` (20 monitors ×
50 slots/s = 1,000 events/s, a 10,000-event burst every 5 s), the app's own main-thread
watchdog (a ping every 10 ms; a hang is a wait of 250 ms or more), optionally under
`xctrace` (Time Profiler + Hangs).

### The UI-stall drill (ROADMAP §N0 learning drill)

1. **Reproduced** — `measure-validate-busy-20261117T013740Z-64c10e4.json`: the first
   measurement of the app as written (SwiftUI `List` of 10,000 rows): one main-thread
   wait of **72.2 s**, a footprint peak of **2.04 GB**, 76 CPU-seconds in a 12-second
   window. A second run under `xctrace` reproduced it (one wait of **78.6 s**, peak
   1.71 GB, 79 CPU-s); that run's result file was lost because the driver script was
   edited while it ran (bash reads scripts incrementally) — those three numbers are
   transcribed from its app report before the temp directory was removed, and that
   trace never finished saving (xctrace hung at its time limit with the target stalled).
2. **Located** — `stall-drill-before-sample-main-thread.txt`: `sample(1)` of the main
   thread mid-stall. All 2,461 samples are in SwiftUI's
   `OutlineListCoordinator.diffRows` → `-[NSTableView endUpdates]` →
   `_doAutomaticRowHeightsForInsertedAndVisibleRows`: with automatic row heights the
   `List` prepares a row view (an `NSHostingView`) for **every inserted row**, visible or
   not, and each one registers a KVO observer on the window whose observation-info copy
   grows with the observers already registered — quadratic in the rows of a batch.
3. **Fixed** — `Sources/NWShell/EventTable.swift`: an AppKit `NSTableView` with fixed
   row heights and `reloadData`, which builds only visible rows (D-026).
   `NW_EVENT_LIST=swiftui-list` (or `measure-app.sh --stall`) brings the old list back
   to reproduce the drill.
4. **Verified** — `measure-table-after-busy-20261117T015917Z-64c10e4.json`, same load,
   busy machine: 42,397 events stored, 10,000 rows in view, **0 hangs**, worst wait
   61.6 ms (p99 0.7 ms), footprint peak **83 MB**, 2.0 CPU-seconds in 20 s, service live.

Owed: the Instruments (Hangs) traces of before and after. The before trace never
finished saving (above); in `measure-table-after-busy-20261117T015748Z-64c10e4.json` the
app never left "Initializing system frameworks" under xctrace on the loaded machine (one
profile sample in 61 s, SIGKILLed at the time limit; xctrace exit 54), so it has no app
report. `measure-stall-locate-busy-20261117T013949Z-64c10e4.json` is an xctrace run where
no event reached the app (every poll of 20 × 500 checks missed the 1 s deadline at load
30+; the deadline is now configurable for measurement, `NW_POLL_DEADLINE_S`). Trace
bundles are not committed (13–14 MB each); their exported hang tables are.
