# Native Developer Workspace

> **Status — optional; exploration N0 in progress (2026-11-16).** The guide
> marks this an OPTIONAL CONCEPT. A time-boxed, read-only exploration
> (N0–N2) is under way; it is not a product commitment and must not slow the
> active products. The concept becomes an active project only if the
> promotion gate after N2 passes (D-011). If it never passes, the project
> honestly stays a concept. N0's code, CI and drills exist; its gate is not
> yet passed — the 1,000,000-event full replay is owed until this Mac is
> quiet enough to run it (`docs/ROADMAP.md` §N0 status).

A macOS-native workbench for the portfolio's own services — Service
Monitor first, later the durable workflow runner, JavaScript-runtime
executions and Colophon release receipts. The first usefulness must come
from one reliable investigation workflow: connect an authorized service,
inspect status and bounded log history, select a failed operation, review
evidence and a proposed action, authorize, observe the result. Swift +
SwiftUI with AppKit where appropriate; the Rust services stay
authoritative — the desktop is a client, never a bypass, and the service's
token scope, not the app, is the security boundary. Read-only first; the
single permitted reversible action arrives only after promotion.

## Build, test, run (exploration)

macOS 26 or later with Xcode (this Mac: Xcode 27.2; CI: Xcode 26.6 on
`macos-26`). `xcode-select` here points at the Command Line Tools, so the
scripts set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```bash
scripts/check.sh                    # what CI runs: format lint, architecture checks
                                    # and their self-test, build, tests, replay smoke
scripts/replay.sh --full            # 1,000,000-event headless replay (needs load < 6)
scripts/drill-real-services.sh      # SIGKILL/restart drill against scratch Service
                                    # Monitor + Durable Runner built from their main
scripts/measure-app.sh --busy       # the app under fixture load, main-thread watchdog
```

The app is an unsigned SwiftPM executable for now (N1 brings the Xcode
project, signing, App Sandbox and the entitled Keychain). It pairs from the
environment under the development exception (D-015): `NW_SMON_URL` (loopback
only) with `NW_SMON_TOKEN`, and/or `NW_DURABLE_URL` (open reads, no
credential). It only ever sends `GET`, and it sends Service Monitor
nothing unless the process listening on the port is the paired program
(`NW_SMON_EXPECT_EXECUTABLE`, else the first one seen; D-015). An
environment token is weak — it usually sits in plain text in a shell
profile and is inherited by child processes — so the app unsets it once
read; N1 replaces it with Keychain pairing.

## Blocked on

Exploration (N0–N2) is not blocked. These need the maintainer or another
project:

| # | Needed | From | Blocks |
|---|---|---|---|
| W-1 | A read-only (viewer) token issued through Service Monitor's public API. Today it has one admin bearer token; per-workspace tokens and a viewer role are planned in its accounts milestone | Service Monitor | pairing with any non-loopback endpoint; the first signed release (N5). Exploration uses a local instance under a development-only exception (D-015) |
| W-2 | A Service Monitor token scope limited to one reversible action (pause/resume a monitor, D-025) | Service Monitor | N4 |
| W-3 | The promotion decision after the pre-registered comparison (D-012) | the maintainer | N3–N5 |
| W-4 | Apple Developer Program membership for Developer ID signing and notarization (D-019) | the maintainer | N5 distribution (development signing needs none) |

## Documents

- `docs/END_GOAL.md` — what done means, scope, invariants, the four
  required failure cases with their tests and pass conditions, the
  promotion gate and the release gate
- `docs/ARCHITECTURE.md` — components, sources of truth, data paths,
  planned layout, consistency story
- `docs/ROADMAP.md` — exploration N0 spine → N1 shell → N2 read-only value
  → promotion review → N3 assistance → N4 one controlled action → N5 signed
  release
- `docs/DECISIONS.md` — native-only UI, service authority, read-only first,
  no FFI before measured need, bounded retention with visible gaps
  (D-001–D-010), the decisions made before code (D-011–D-025) and the
  questions still open

Contract: the engineering guide `10_Native_Developer_Workspace.docx` (kept
in the maintainer's workspace under `docs/Project_Guides/`, not in this
repository).

**What counts as done:** first, the promotion gate — the read-only
investigation workflow beats the existing terminal and web interface on a
pre-registered comparison, with failure cases 1, 2 and the revocation half
of 4 proven and the 1,000,000-event run recorded (machine + commit). Then,
only if promoted, the release gate: all four failure cases proven and a
signed, notarized build with documented update behavior.
