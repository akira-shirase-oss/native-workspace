# Fixtures

Recorded service shapes and event streams for tests and drills (AGENTS §Testing rule).
The services' read APIs are emulated in code (`Sources/NWFixtures/Emulators.swift`,
shaped after Service Monitor's `crates/monitor-server/src/lib.rs` and Durable Runner's
`crates/durable-server/src/main.rs`) and served by `FixtureHTTPServer`, a loopback
HTTP/1.1 server that can be killed and restarted and that records every request's method.

| Fixture | Where | Status |
|---|---|---|
| `hostile-log-lines` | `hostile-log-lines.json`; the same corpus in `InertTextTests` and the emulator's failing-check details | N0: used |
| `burst-10k` | `nw-fixture-server --burst-every 5 --burst-size 10000`; `IngestQueueTests` (ten repeated 15,000-event bursts); the replay's overload bursts | N0: package level. The app-level run under Instruments is N2 |
| `disconnect-restart` | `DisconnectRestartDrillTests` (fixture server, random kill/restart points) and `RealServiceDrillTests` + `scripts/drill-real-services.sh` (scratch Service Monitor and Durable Runner, SIGKILL) | N0: used |
| `revoked-credential` | `ServiceMonitorEmulator.revoke()`; `ServiceConnectionTests` | N0: package level. The UI test is N1 |
| `lossy-wire` | `LossyDecodeTests`: invalid UTF-8 bytes and lone `\uD800`–`\uDFFF` escapes inside otherwise valid Service Monitor and Durable Runner responses, plus items of the wrong shape | used: repaired to U+FFFD, unreadable items skipped and counted |
| `secret-corpus` | — | Owed at N2 with the redactor (D-017) |
| `unsafe-proposal` | — | N3, after promotion |
| `disconnect-mid-action` | — | N4, after promotion |

The emulators answer any method other than `GET` with 405 and count it; tests assert that
count is zero, so the server side witnesses the read-only rule as well as the client.
