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
| (no file) first 1,000-iteration package run, 20:21 | — | **hung, fixture bug**: after about 46 minutes the test process sat at 0% CPU. The fixture server's `start()` waited without a deadline for its listener to become ready and ignored NWListener's `waiting` state (a port not yet released after a kill, rare and only under load). Start and stop are now bounded with retry; `FixtureServerTests` proves a start on a held port fails within its timeout and that 200 kill-restarts on one port stay bounded. The rerun is the `package-disconnect-restart-1000-*` file |
| `real-disconnect-restart-20261117T020729Z-f232c6a.json` | The same real drill on the committed tree `f232c6a`, × 5 | **pass**: stale 0.011–1.94 s after each kill, live again 1.2–7.6 s after each restart (bounded by the backoff step reached in 4.6–8.1 s of downtime), 29 events acknowledged, 0 lost, 0 duplicate rows |
| `real-disconnect-restart-20261117T013356Z-64c10e4.json` | Real scratch Service Monitor (`659e468`) and Durable Runner (`3da25ef`) on 127.0.0.1:60410/60420, data under `/tmp`, SIGKILL + restart × 5, the shell's `AppModel` with the contract timings (2 s polls, 1 s grace, backoff 1 s → 30 s) | **pass**: stale 0.01–1.69 s after each kill (bound 3 s), live again 1.8–3.0 s after each restart without re-pairing, 0 live samples while down, 0 green while not live, 30 events acknowledged, 0 lost, 0 duplicate rows, also after reopening the store from disk. Commit is `64c10e4+dirty` (the slice-3 working tree, before it was committed) |
| `real-disconnect-restart-20261117T012912Z-64c10e4.driver-bug.json` | First real run | **fail, driver bug**: the driver's `kill -9` hit the wrapping subshell, so the services never died; the test correctly reported 226 live samples "while down". Fixed with `exec` and a port-closed check after every kill |
| `real-disconnect-restart-20261117T013102Z-64c10e4.window-bug.json` | Second real run | **fail, 3 live samples in the down window.** The window ended at the driver's "restarted" marker, written only after both services answered, so a poll could land after the real restart and inside the window. The window now ends when the restart begins (`restarting-N`) and the samples between restart-begin and the marker are recorded (0 in the passing run). The explanation is consistent with the data but was not proven by a reproduction |

## Replay — `replay-1m-*.json`

`scripts/replay.sh --full`: 1,000,000 events through the bounded queue (10,000), the
on-disk store (`F_FULLFSYNC` per batch, 50,000 retained) and the main-actor event list
(10,000 rows), offered at 20,000 events/s in 10,000-event bursts, every 10th burst an
overload of 20,000 that must drop, every 20th preceded by 1,000 re-offered duplicates.
The full run refuses to start at a 1-minute load average of 6 or more; until a quiet run
exists the result is **owed**. Only smokes have run: CI's 30,000-event smoke, and
`replay-smoke-busy-*-4d16592.json` (release build, load 30+): the ledger is exact —
35,000 offered = 33,000 admitted + 2,000 dropped, gap counts 2,000, 33,000 admitted =
29,000 acknowledged + 4,000 refused duplicates — with 0 main-thread hangs (worst wait
2.7 ms), a 28.7 MB peak, and an offer-to-visible p99 of 520 ms (100 ms batching plus a
`F_FULLFSYNC` of up to 10,000 events per batch on a loaded disk).

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
2. **Located** — first with `sample(1)` (`stall-drill-before-sample-main-thread.txt`),
   then with Instruments attached to the stalled app for 15 s
   (`stall-drill-before-instruments-20261117T0215Z-4d16592.json`): **100%** of 15,666
   main-thread samples are inside SwiftUI's `OutlineListCoordinator.diffRows`
   (`List`'s diff applied to the backing `NSTableView`), **77.6%** in
   `NSHostingView.viewWillMove(toWindow:)` — a hosting view built and attached for
   every inserted row, visible or not (10,000 per batch here, against about 30 on
   screen). The leaf time is mostly notification-observer removal (36%) and KVO
   observation-info hashing (27%), work that grows with the observers already on the
   window — consistent with a cost that grows faster than the batch, not a proof of it.
   (The slice-3 commit message called it quadratic; that was more than the evidence
   showed.) The Hangs table of that trace is empty because the hang was still in
   progress when the recording ended.
3. **Fixed** — `Sources/NWShell/EventTable.swift`: an AppKit `NSTableView` with fixed
   row heights and `reloadData`, which builds only visible rows (D-026).
   `NW_EVENT_LIST=swiftui-list` (or `measure-app.sh --stall`) brings the old list back
   to reproduce the drill.
4. **Verified** — `measure-table-after-busy-20261117T015917Z-64c10e4.json` (watchdog,
   20 s): 42,397 events stored, 10,000 rows in view, **0 hangs**, worst wait 61.6 ms
   (p99 0.7 ms), footprint peak **83 MB**, 2.0 CPU-seconds. And under Instruments
   (`stall-drill-after-instruments-20261117T0218Z-4d16592.json` plus its exported,
   empty `potential-hangs` table): attached for 15 s at load 92, **0 hang rows**, the
   main thread on CPU in 383 samples instead of 15,666; the app's watchdog over its 30 s
   run: 0 hangs, worst wait 41.4 ms, 76,631 events stored, peak 94.6 MB, 3.5 CPU-s.

Kept misses of the Instruments path: the first before-trace never finished saving
(xctrace hung at its time limit with the target stalled — attaching to an already
stalled app is what worked); in `measure-table-after-busy-20261117T015748Z-64c10e4.json`
the app launched by xctrace never left "Initializing system frameworks" on the loaded
machine (one profile sample in 61 s, SIGKILLed at the time limit, xctrace exit 54), so
it has no app report; `measure-stall-locate-busy-20261117T013949Z-64c10e4.json` is an
xctrace run where no event reached the app (every poll of 20 × 500 checks missed the
1 s deadline at load 30+; the deadline is now configurable for measurement,
`NW_POLL_DEADLINE_S`). Trace bundles are not committed (13–25 MB each); their
summaries and exported hang tables are.
